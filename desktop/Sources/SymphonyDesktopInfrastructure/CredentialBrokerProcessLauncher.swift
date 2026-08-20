import Darwin
import Foundation
import SymphonyCredentialBrokerProtocol
import SymphonyDesktopCore

public protocol CredentialBrokerSessionHandle: Sendable {
  /// Returns only after the broker process no longer retains namespace credentials.
  func lock() async throws
}

public protocol CredentialBrokerSessionLaunching: Sendable {
  func unlock(namespaceID: Namespace.ID) async throws -> any CredentialBrokerSessionHandle
  func purge(namespaceID: Namespace.ID) async throws
}

public struct CredentialBrokerProcessLauncher: CredentialBrokerSessionLaunching {
  private let executableURL: URL?
  private let handshakeTimeout: TimeInterval
  private let stopTimeout: TimeInterval
  private let environment: [String: String]

  public init(
    executableURL: URL?,
    handshakeTimeout: TimeInterval = 60,
    stopTimeout: TimeInterval = 2,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.executableURL = executableURL
    self.handshakeTimeout = handshakeTimeout
    self.stopTimeout = stopTimeout
    self.environment = NamespaceProcessEnvironment.sanitized(environment)
  }

  public func unlock(namespaceID: Namespace.ID) async throws -> any CredentialBrokerSessionHandle {
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

    do {
      try process.run()
    } catch {
      throw CredentialBrokerProcessError.launchFailed(error.localizedDescription)
    }

    let processReference = UnsafeProcessReference(process)
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
          process: process,
          input: input.fileHandleForWriting,
          output: output.fileHandleForReading,
          errorOutput: errorOutput.fileHandleForReading,
          stopTimeout: stopTimeout
        )
      case .failed(let message):
        try await ProcessCredentialBrokerSession.stop(
          processReference,
          input: input.fileHandleForWriting,
          timeout: stopTimeout
        )
        throw CredentialBrokerProcessError.unlockFailed(message)
      }
    } catch {
      try? await ProcessCredentialBrokerSession.stop(
        processReference,
        input: input.fileHandleForWriting,
        timeout: stopTimeout
      )
      output.fileHandleForReading.closeFile()
      errorOutput.fileHandleForReading.closeFile()
      throw error
    }
  }

  public func purge(namespaceID: Namespace.ID) async throws {
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
    guard await ProcessCredentialBrokerSession.waitForExit(processReference, timeout: stopTimeout)
    else {
      try? await ProcessCredentialBrokerSession.stop(
        processReference,
        input: nil,
        timeout: stopTimeout
      )
      throw CredentialBrokerProcessError.stopTimedOut
    }
    guard process.terminationStatus == 0 else {
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
}

private actor ProcessCredentialBrokerSession: CredentialBrokerSessionHandle {
  private let process: UnsafeProcessReference
  private let input: FileHandle
  private let output: FileHandle
  private let errorOutput: FileHandle
  private let stopTimeout: TimeInterval
  private var stopped = false

  init(
    process: Process,
    input: FileHandle,
    output: FileHandle,
    errorOutput: FileHandle,
    stopTimeout: TimeInterval
  ) {
    self.process = UnsafeProcessReference(process)
    self.input = input
    self.output = output
    self.errorOutput = errorOutput
    self.stopTimeout = stopTimeout
  }

  func lock() async throws {
    guard !stopped else {
      return
    }
    try await Self.stop(process, input: input, timeout: stopTimeout)
    stopped = true
    output.closeFile()
    errorOutput.closeFile()
  }

  static func stop(
    _ process: UnsafeProcessReference,
    input: FileHandle?,
    timeout: TimeInterval
  ) async throws {
    if process.isRunning {
      if let input {
        try? input.write(contentsOf: Data("lock\n".utf8))
        try? input.close()
      }
      if await waitForExit(process, timeout: timeout) {
        return
      }
      process.terminate()
      if await waitForExit(process, timeout: timeout) {
        return
      }
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
      guard await waitForExit(process, timeout: timeout) else {
        throw CredentialBrokerProcessError.stopTimedOut
      }
    }
  }

  static func waitForExit(
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

private final class UnsafeProcessReference: @unchecked Sendable {
  let process: Process

  init(_ process: Process) {
    self.process = process
  }

  var isRunning: Bool { process.isRunning }
  var processIdentifier: Int32 { process.processIdentifier }
  func terminate() { process.terminate() }
}

private enum BrokerPipeReader {
  static func readLine(from descriptor: Int32, timeout: TimeInterval) throws -> Data {
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
      guard accumulated.count <= 16_384 else {
        throw CredentialBrokerProcessError.handshakeFailed
      }
    }
    throw CredentialBrokerProcessError.handshakeTimedOut
  }
}

public enum CredentialBrokerProcessError: LocalizedError, Sendable {
  case executableNotFound
  case executableNotExecutable(URL)
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
