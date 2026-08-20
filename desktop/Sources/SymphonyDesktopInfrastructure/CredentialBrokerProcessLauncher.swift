import Darwin
import Foundation
import SymphonyCredentialBrokerProtocol
import SymphonyDesktopCore

public protocol CredentialBrokerSessionHandle: Sendable {
  func signChallenge(_ challenge: Data) async throws -> Data
  /// Returns only after the broker process no longer retains namespace credentials.
  func lock() async throws
}

public protocol CredentialBrokerSessionLaunching: Sendable {
  func unlock(namespaceID: Namespace.ID) async throws -> any CredentialBrokerSessionHandle
  /// Returns only after no broker process remains owned for `namespaceID`.
  func stop(namespaceID: Namespace.ID) async throws
  func purge(namespaceID: Namespace.ID) async throws
}

public actor CredentialBrokerProcessLauncher: CredentialBrokerSessionLaunching {
  public typealias ForceKill = @Sendable (Int32) -> Int32

  private struct Runtime {
    let generation: UUID
    let process: UnsafeProcessReference
    let input: FileHandle?
    let output: FileHandle?
    let errorOutput: FileHandle?
  }

  private let executableURL: URL?
  private let handshakeTimeout: TimeInterval
  private let stopTimeout: TimeInterval
  private let environment: [String: String]
  private let forceKill: ForceKill
  private var runtimes: [Namespace.ID: Runtime] = [:]
  private var commandOwners: Set<Namespace.ID> = []
  private var stopTasks: [Namespace.ID: Task<Void, Error>] = [:]

  public init(
    executableURL: URL?,
    handshakeTimeout: TimeInterval = 60,
    stopTimeout: TimeInterval = 2,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    forceKill: @escaping ForceKill = { Darwin.kill($0, SIGKILL) }
  ) {
    self.executableURL = executableURL
    self.handshakeTimeout = handshakeTimeout
    self.stopTimeout = stopTimeout
    self.environment = NamespaceProcessEnvironment.sanitized(environment)
    self.forceKill = forceKill
  }

  public func unlock(namespaceID: Namespace.ID) async throws -> any CredentialBrokerSessionHandle {
    guard runtimes[namespaceID] == nil else {
      throw CredentialBrokerProcessError.sessionAlreadyRunning
    }
    let executableURL = try requireExecutable()
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errorOutput = Pipe()
    process.executableURL = executableURL
    process.arguments = ["serve", namespaceID.uuidString.lowercased()]
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errorOutput
    _ = Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    do {
      try process.run()
    } catch {
      throw CredentialBrokerProcessError.launchFailed(error.localizedDescription)
    }

    let processReference = UnsafeProcessReference(process)
    let generation = UUID()
    let runtime = Runtime(
      generation: generation,
      process: processReference,
      input: input.fileHandleForWriting,
      output: output.fileHandleForReading,
      errorOutput: errorOutput.fileHandleForReading
    )
    runtimes[namespaceID] = runtime
    let handshakeTimeout = self.handshakeTimeout
    do {
      let responseData = try await withTaskCancellationHandler {
        try await Task.detached {
          try BrokerPipeReader.readLine(
            from: output.fileHandleForReading.fileDescriptor,
            timeout: handshakeTimeout
          )
        }.value
      } onCancel: {
        processReference.terminate()
      }
      let handshake = try JSONDecoder().decode(CredentialBrokerHandshake.self, from: responseData)
      switch handshake {
      case .unlocked:
        return ProcessCredentialBrokerSession(
          namespaceID: namespaceID,
          generation: generation,
          launcher: self
        )
      case .failed(let message):
        try await stop(namespaceID: namespaceID, generation: generation)
        throw CredentialBrokerProcessError.unlockFailed(message)
      }
    } catch {
      try await stop(namespaceID: namespaceID, generation: generation)
      throw error
    }
  }

  public func stop(namespaceID: Namespace.ID) async throws {
    guard let runtime = runtimes[namespaceID] else {
      return
    }
    try await stop(namespaceID: namespaceID, generation: runtime.generation)
  }

  fileprivate func signChallenge(
    _ challenge: Data,
    namespaceID: Namespace.ID,
    generation: UUID
  ) async throws -> Data {
    guard challenge.count <= 32_768 else {
      throw CredentialBrokerProcessError.requestTooLarge
    }
    try await acquireCommand(for: namespaceID)
    defer { releaseCommand(for: namespaceID) }
    guard let runtime = runtimes[namespaceID], runtime.generation == generation else {
      throw CredentialBrokerProcessError.sessionNotRunning
    }
    guard let input = runtime.input, let output = runtime.output else {
      throw CredentialBrokerProcessError.sessionNotRunning
    }
    let outputDescriptor = output.fileDescriptor
    let responseTimeout = handshakeTimeout
    do {
      var command = try JSONEncoder().encode(CredentialBrokerCommand.signChallenge(challenge))
      command.append(0x0A)
      try input.write(contentsOf: command)
      let responseData = try await Task.detached {
        try BrokerPipeReader.readLine(
          from: outputDescriptor,
          timeout: responseTimeout,
          maximumBytes: 65_536
        )
      }.value
      switch try JSONDecoder().decode(CredentialBrokerResult.self, from: responseData) {
      case .signature(let signature):
        return signature
      case .failed(let message):
        throw CredentialBrokerProcessError.capabilityFailed(message)
      case .locked:
        throw CredentialBrokerProcessError.handshakeFailed
      }
    } catch {
      if stopTasks[namespaceID] == nil {
        do {
          try await stop(namespaceID: namespaceID, generation: generation)
        } catch {
          throw error
        }
      }
      throw error
    }
  }

  public func purge(namespaceID: Namespace.ID) async throws {
    try await stop(namespaceID: namespaceID)
    let executableURL = try requireExecutable()
    let process = Process()
    let errorOutput = Pipe()
    process.executableURL = executableURL
    process.arguments = ["purge", namespaceID.uuidString.lowercased()]
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorOutput

    do {
      try process.run()
    } catch {
      throw CredentialBrokerProcessError.launchFailed(error.localizedDescription)
    }

    let processReference = UnsafeProcessReference(process)
    let generation = UUID()
    runtimes[namespaceID] = Runtime(
      generation: generation,
      process: processReference,
      input: nil,
      output: nil,
      errorOutput: errorOutput.fileHandleForReading
    )
    guard await Self.waitForExit(processReference, timeout: stopTimeout) else {
      try await stop(namespaceID: namespaceID, generation: generation)
      throw CredentialBrokerProcessError.stopTimedOut
    }
    let terminationStatus = processReference.terminationStatus
    try await stop(namespaceID: namespaceID, generation: generation)
    guard terminationStatus == 0 else {
      throw CredentialBrokerProcessError.purgeFailed
    }
  }

  private func requireExecutable() throws -> URL {
    guard let executableURL else {
      throw CredentialBrokerProcessError.executableNotFound
    }
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw CredentialBrokerProcessError.executableNotExecutable(executableURL)
    }
    return executableURL
  }

  fileprivate func stop(namespaceID: Namespace.ID, generation: UUID) async throws {
    if let stopTask = stopTasks[namespaceID] {
      try await stopTask.value
      return
    }
    guard let runtime = runtimes[namespaceID], runtime.generation == generation else {
      return
    }
    runtime.output?.closeFile()
    let stopTask = Task {
      try await Self.stopProcess(
        runtime.process,
        input: runtime.input,
        timeout: stopTimeout,
        forceKill: forceKill
      )
    }
    stopTasks[namespaceID] = stopTask
    do {
      try await stopTask.value
    } catch {
      stopTasks.removeValue(forKey: namespaceID)
      throw error
    }
    stopTasks.removeValue(forKey: namespaceID)
    guard runtimes[namespaceID]?.generation == generation else {
      return
    }
    runtimes.removeValue(forKey: namespaceID)
    runtime.output?.closeFile()
    runtime.errorOutput?.closeFile()
  }

  private func acquireCommand(for namespaceID: Namespace.ID) async throws {
    while commandOwners.contains(namespaceID) {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(10))
    }
    try Task.checkCancellation()
    commandOwners.insert(namespaceID)
  }

  private func releaseCommand(for namespaceID: Namespace.ID) {
    commandOwners.remove(namespaceID)
  }

  private static func stopProcess(
    _ process: UnsafeProcessReference,
    input: FileHandle?,
    timeout: TimeInterval,
    forceKill: ForceKill
  ) async throws {
    if process.isRunning {
      if let input {
        if var command = try? JSONEncoder().encode(CredentialBrokerCommand.lock) {
          command.append(0x0A)
          try? input.write(contentsOf: command)
        }
        try? input.close()
      }
      if await waitForExit(process, timeout: timeout) {
        return
      }
      process.terminate()
      if await waitForExit(process, timeout: timeout) {
        return
      }
      guard forceKill(process.processIdentifier) == 0 else {
        throw CredentialBrokerProcessError.stopTimedOut
      }
      guard await waitForExit(process, timeout: timeout) else {
        throw CredentialBrokerProcessError.stopTimedOut
      }
    }
  }

  private static func waitForExit(
    _ process: UnsafeProcessReference,
    timeout: TimeInterval
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while process.isRunning, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return !process.isRunning
  }
}

private struct ProcessCredentialBrokerSession: CredentialBrokerSessionHandle {
  private let namespaceID: Namespace.ID
  private let generation: UUID
  private let launcher: CredentialBrokerProcessLauncher

  init(
    namespaceID: Namespace.ID,
    generation: UUID,
    launcher: CredentialBrokerProcessLauncher
  ) {
    self.namespaceID = namespaceID
    self.generation = generation
    self.launcher = launcher
  }

  func lock() async throws {
    try await launcher.stop(namespaceID: namespaceID, generation: generation)
  }

  func signChallenge(_ challenge: Data) async throws -> Data {
    try await launcher.signChallenge(
      challenge,
      namespaceID: namespaceID,
      generation: generation
    )
  }
}

private final class UnsafeProcessReference: @unchecked Sendable {
  let process: Process

  init(_ process: Process) {
    self.process = process
  }

  var isRunning: Bool { process.isRunning }
  var processIdentifier: Int32 { process.processIdentifier }
  var terminationStatus: Int32 { process.terminationStatus }
  func terminate() { process.terminate() }
}

private enum BrokerPipeReader {
  static func readLine(
    from descriptor: Int32,
    timeout: TimeInterval,
    maximumBytes: Int = 16_384
  ) throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    var accumulated = Data()

    while Date() < deadline {
      let remaining = max(0, deadline.timeIntervalSinceNow)
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let result = Darwin.poll(&pollDescriptor, 1, Int32(remaining * 1_000))
      if result == 0 {
        break
      }
      if result < 0 {
        if errno == EINTR { continue }
        throw CredentialBrokerProcessError.handshakeFailed
      }

      var buffer = [UInt8](repeating: 0, count: 1_024)
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count <= 0 {
        throw CredentialBrokerProcessError.handshakeFailed
      }
      accumulated.append(contentsOf: buffer.prefix(count))
      if let newline = accumulated.firstIndex(of: 0x0A) {
        return accumulated[..<newline]
      }
      guard accumulated.count <= maximumBytes else {
        throw CredentialBrokerProcessError.handshakeFailed
      }
    }
    throw CredentialBrokerProcessError.handshakeTimedOut
  }
}

public enum CredentialBrokerProcessError: LocalizedError, Sendable {
  case executableNotFound
  case executableNotExecutable(URL)
  case sessionAlreadyRunning
  case sessionNotRunning
  case requestTooLarge
  case capabilityFailed(String)
  case launchFailed(String)
  case handshakeFailed
  case handshakeTimedOut
  case unlockFailed(String)
  case purgeFailed
  case stopTimedOut

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "The native credential broker could not be found. Reinstall Symphony and try again."
    case .executableNotExecutable(let url):
      "The native credential broker is not executable at \(url.path). Reinstall Symphony and try again."
    case .sessionAlreadyRunning:
      "A native credential broker process is already owned for this namespace. Lock it before trying again."
    case .sessionNotRunning:
      "The namespace credential broker is not running. Unlock the namespace and try again."
    case .requestTooLarge:
      "The credential capability request is too large."
    case .capabilityFailed(let message):
      message
    case .launchFailed(let message):
      "The native credential broker could not start: \(message)"
    case .handshakeFailed:
      "The native credential broker stopped before unlock completed."
    case .handshakeTimedOut:
      "Namespace unlock timed out. Try again."
    case .unlockFailed(let message):
      message
    case .purgeFailed:
      "Protected namespace credentials could not be removed. Try again before deleting the namespace."
    case .stopTimedOut:
      "The native credential broker could not be stopped safely. Try again before quitting or deleting the namespace."
    }
  }
}
