import Darwin
import Foundation
import SymphonyCredentialBrokerProtocol
import SymphonyDesktopCore

@_silgen_name("proc_listchildpids")
private func symphonyListChildProcessIDs(_ parent: pid_t, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

public protocol CredentialBrokerSessionHandle: Sendable {
  func signChallenge(_ challenge: Data) async throws -> Data
  /// Returns only after the broker process no longer retains namespace credentials.
  func lock() async throws
}

public protocol GitHubCredentialBrokerConfigurationSessionHandle: Sendable {
  func configureGitHubApp(appID: Int64, privateKeyFileURL: URL) async throws
  func listGitHubInstallations() async throws -> [GitHubInstallationDescriptor]
  func listGitHubRepositories(
    installationID: Int64
  ) async throws -> [GitHubRepositoryDescriptor]
  func authorizeGitHubRepository(_ authorization: GitHubRepositoryAuthorization) async throws
}

public protocol GitHubRepositoryCapabilitySessionHandle: Sendable {
  func performGitHubIssueRequest(
    _ request: GitHubIssueCapabilityRequest
  ) async throws -> GitHubIssueCapabilityResponse
  func performGitHubGitOperation(
    _ request: GitRepositoryCapabilityRequest
  ) async throws -> GitRepositoryCapabilityResult
}

public protocol NamespaceCredentialBrokerSessionHandle:
  CredentialBrokerSessionHandle,
  GitHubCredentialBrokerConfigurationSessionHandle,
  GitHubRepositoryCapabilitySessionHandle {}

public protocol CredentialBrokerSessionLaunching: Sendable {
  func unlock(namespaceID: Namespace.ID) async throws -> any NamespaceCredentialBrokerSessionHandle
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
    let readCancellation: BrokerReadCancellation
  }

  private let executableURL: URL?
  private let handshakeTimeout: TimeInterval
  private let capabilityTimeout: TimeInterval
  private let stopTimeout: TimeInterval
  private let environment: [String: String]
  private let forceKill: ForceKill
  private let commandGate: NamespaceCommandGate
  private var runtimes: [Namespace.ID: Runtime] = [:]
  private var stopTasks: [Namespace.ID: Task<Void, Error>] = [:]

  public init(
    executableURL: URL?,
    handshakeTimeout: TimeInterval = 60,
    capabilityTimeout: TimeInterval = CredentialBrokerProtocolLimits.defaultCapabilityTimeout,
    stopTimeout: TimeInterval = 2,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    forceKill: @escaping ForceKill = { Darwin.kill($0, SIGKILL) }
  ) {
    self.executableURL = executableURL
    self.handshakeTimeout = handshakeTimeout
    self.capabilityTimeout = capabilityTimeout
    self.stopTimeout = stopTimeout
    self.environment = NamespaceProcessEnvironment.sanitized(environment)
    self.forceKill = forceKill
    commandGate = NamespaceCommandGate()
  }

  init(
    executableURL: URL?,
    handshakeTimeout: TimeInterval,
    capabilityTimeout: TimeInterval = CredentialBrokerProtocolLimits.defaultCapabilityTimeout,
    stopTimeout: TimeInterval,
    environment: [String: String],
    forceKill: @escaping ForceKill,
    commandGate: NamespaceCommandGate
  ) {
    self.executableURL = executableURL
    self.handshakeTimeout = handshakeTimeout
    self.capabilityTimeout = capabilityTimeout
    self.stopTimeout = stopTimeout
    self.environment = NamespaceProcessEnvironment.sanitized(environment)
    self.forceKill = forceKill
    self.commandGate = commandGate
  }

  public func unlock(
    namespaceID: Namespace.ID
  ) async throws -> any NamespaceCredentialBrokerSessionHandle {
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
    guard Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw CredentialBrokerProcessError.pipeConfigurationFailed
    }

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
      errorOutput: errorOutput.fileHandleForReading,
      readCancellation: BrokerReadCancellation()
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
    switch try await perform(
      .signChallenge(challenge),
      namespaceID: namespaceID,
      generation: generation
    ) {
    case .signature(let signature):
      return signature
    case .failed(let message):
      throw CredentialBrokerProcessError.capabilityFailed(message)
    default:
      throw CredentialBrokerProcessError.invalidCapabilityResponse
    }
  }

  fileprivate func configureGitHubApp(
    appID: Int64,
    privateKeyFileURL: URL,
    namespaceID: Namespace.ID,
    generation: UUID
  ) async throws {
    switch try await perform(
      .configureGitHubApp(appID: appID, privateKeyFilePath: privateKeyFileURL.path),
      namespaceID: namespaceID,
      generation: generation
    ) {
    case .githubAppConfigured:
      return
    case .failed(let message):
      throw CredentialBrokerProcessError.capabilityFailed(message)
    default:
      throw CredentialBrokerProcessError.invalidCapabilityResponse
    }
  }

  fileprivate func listGitHubInstallations(
    namespaceID: Namespace.ID,
    generation: UUID
  ) async throws -> [GitHubInstallationDescriptor] {
    switch try await perform(
      .listGitHubInstallations,
      namespaceID: namespaceID,
      generation: generation
    ) {
    case .githubInstallations(let installations):
      return installations
    case .failed(let message):
      throw CredentialBrokerProcessError.capabilityFailed(message)
    default:
      throw CredentialBrokerProcessError.invalidCapabilityResponse
    }
  }

  fileprivate func listGitHubRepositories(
    installationID: Int64,
    namespaceID: Namespace.ID,
    generation: UUID
  ) async throws -> [GitHubRepositoryDescriptor] {
    switch try await perform(
      .listGitHubRepositories(installationID: installationID),
      namespaceID: namespaceID,
      generation: generation
    ) {
    case .githubRepositories(let repositories):
      return repositories
    case .failed(let message):
      throw CredentialBrokerProcessError.capabilityFailed(message)
    default:
      throw CredentialBrokerProcessError.invalidCapabilityResponse
    }
  }

  fileprivate func authorizeGitHubRepository(
    _ authorization: GitHubRepositoryAuthorization,
    namespaceID: Namespace.ID,
    generation: UUID
  ) async throws {
    switch try await perform(
      .authorizeGitHubRepository(authorization),
      namespaceID: namespaceID,
      generation: generation
    ) {
    case .githubRepositoryAuthorized:
      return
    case .githubCapabilityFailed(let failure):
      throw GitHubCapabilityError(failure)
    case .failed(let message):
      throw CredentialBrokerProcessError.capabilityFailed(message)
    default:
      throw CredentialBrokerProcessError.invalidCapabilityResponse
    }
  }

  fileprivate func performGitHubIssueRequest(
    _ request: GitHubIssueCapabilityRequest,
    namespaceID: Namespace.ID,
    generation: UUID
  ) async throws -> GitHubIssueCapabilityResponse {
    switch try await perform(
      .performGitHubIssueRequest(request),
      namespaceID: namespaceID,
      generation: generation
    ) {
    case .githubIssueResponse(let response):
      return response
    case .githubCapabilityFailed(let failure):
      throw GitHubCapabilityError(failure)
    case .failed(let message):
      throw CredentialBrokerProcessError.capabilityFailed(message)
    default:
      throw CredentialBrokerProcessError.invalidCapabilityResponse
    }
  }

  fileprivate func performGitHubGitOperation(
    _ request: GitRepositoryCapabilityRequest,
    namespaceID: Namespace.ID,
    generation: UUID
  ) async throws -> GitRepositoryCapabilityResult {
    switch try await perform(
      .performGitHubGitOperation(request),
      namespaceID: namespaceID,
      generation: generation
    ) {
    case .githubGitResult(let result):
      return result
    case .githubCapabilityFailed(let failure):
      throw GitHubCapabilityError(failure)
    case .failed(let message):
      throw CredentialBrokerProcessError.capabilityFailed(message)
    default:
      throw CredentialBrokerProcessError.invalidCapabilityResponse
    }
  }

  private func perform(
    _ command: CredentialBrokerCommand,
    namespaceID: Namespace.ID,
    generation: UUID
  ) async throws -> CredentialBrokerResult {
    try await acquireCommand(for: namespaceID)
    defer { commandGate.release(namespaceID) }
    guard let runtime = runtimes[namespaceID], runtime.generation == generation else {
      throw CredentialBrokerProcessError.sessionNotRunning
    }
    guard let input = runtime.input, let output = runtime.output else {
      throw CredentialBrokerProcessError.sessionNotRunning
    }
    let outputDescriptor = output.fileDescriptor
    let responseTimeout = capabilityTimeout
    do {
      var requestData = try JSONEncoder().encode(command)
      guard requestData.count <= CredentialBrokerProtocolLimits.maximumCommandBytes else {
        throw CredentialBrokerProcessError.requestTooLarge
      }
      requestData.append(0x0A)
      try input.write(contentsOf: requestData)
      let responseData = try await Task.detached {
        try BrokerPipeReader.readLine(
          from: outputDescriptor,
          timeout: responseTimeout,
          maximumBytes: CredentialBrokerProtocolLimits.maximumResponseBytes,
          context: .capability,
          cancellation: runtime.readCancellation
        )
      }.value
      do {
        return try JSONDecoder().decode(CredentialBrokerResult.self, from: responseData)
      } catch {
        throw CredentialBrokerProcessError.invalidCapabilityResponse
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
      errorOutput: errorOutput.fileHandleForReading,
      readCancellation: BrokerReadCancellation()
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
    runtime.readCancellation.cancel()
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
    try await commandGate.acquire(namespaceID)
  }

  private static func stopProcess(
    _ process: UnsafeProcessReference,
    input: FileHandle?,
    timeout: TimeInterval,
    forceKill: ForceKill
  ) async throws {
    var descendantGroups = descendantProcessGroups(of: process.processIdentifier)
    if process.isRunning {
      if let input {
        if var command = try? JSONEncoder().encode(CredentialBrokerCommand.lock) {
          command.append(0x0A)
          try? input.write(contentsOf: command)
        }
        try? input.close()
      }
      if await waitForExit(process, timeout: timeout, descendantGroups: &descendantGroups) {
        try await stopDescendantGroups(descendantGroups, timeout: timeout)
        return
      }
      process.terminate()
      if await waitForExit(process, timeout: timeout, descendantGroups: &descendantGroups) {
        try await stopDescendantGroups(descendantGroups, timeout: timeout)
        return
      }
      guard forceKill(process.processIdentifier) == 0 else {
        throw CredentialBrokerProcessError.stopTimedOut
      }
      guard await waitForExit(process, timeout: timeout, descendantGroups: &descendantGroups) else {
        throw CredentialBrokerProcessError.stopTimedOut
      }
    }
    try await stopDescendantGroups(descendantGroups, timeout: timeout)
  }

  private static func waitForExit(
    _ process: UnsafeProcessReference,
    timeout: TimeInterval
  ) async -> Bool {
    var descendantGroups: Set<Int32> = []
    return await waitForExit(
      process,
      timeout: timeout,
      descendantGroups: &descendantGroups
    )
  }

  private static func waitForExit(
    _ process: UnsafeProcessReference,
    timeout: TimeInterval,
    descendantGroups: inout Set<Int32>
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while process.isRunning, ContinuousClock.now < deadline {
      descendantGroups.formUnion(descendantProcessGroups(of: process.processIdentifier))
      try? await Task.sleep(for: .milliseconds(20))
    }
    descendantGroups.formUnion(descendantProcessGroups(of: process.processIdentifier))
    return !process.isRunning
  }

  private static func descendantProcessGroups(of parent: Int32) -> Set<Int32> {
    var pending = [parent]
    var visited: Set<Int32> = []
    var groups: Set<Int32> = []
    while let current = pending.popLast() {
      guard visited.insert(current).inserted else { continue }
      let childCount = Int(symphonyListChildProcessIDs(current, nil, 0))
      guard childCount > 0 else { continue }
      var children = [pid_t](repeating: 0, count: childCount)
      let writtenCount = children.withUnsafeMutableBytes {
        symphonyListChildProcessIDs(current, $0.baseAddress, Int32($0.count))
      }
      guard writtenCount > 0 else { continue }
      for child in children.prefix(Int(writtenCount)) where child > 0 {
        pending.append(child)
        let group = Darwin.getpgid(child)
        if group > 0, group != Darwin.getpgid(parent) { groups.insert(group) }
      }
    }
    return groups
  }

  private static func stopDescendantGroups(
    _ groups: Set<Int32>,
    timeout: TimeInterval
  ) async throws {
    let liveGroups = groups.filter(groupExists)
    liveGroups.forEach { _ = Darwin.kill(-$0, SIGTERM) }
    if await waitForGroups(liveGroups, timeout: timeout) { return }
    liveGroups.filter(groupExists).forEach { _ = Darwin.kill(-$0, SIGKILL) }
    guard await waitForGroups(liveGroups, timeout: timeout) else {
      throw CredentialBrokerProcessError.stopTimedOut
    }
  }

  private static func waitForGroups(_ groups: Set<Int32>, timeout: TimeInterval) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while groups.contains(where: groupExists), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return !groups.contains(where: groupExists)
  }

  private static func groupExists(_ group: Int32) -> Bool {
    let result = Darwin.kill(-group, 0)
    return result == 0 || errno == EPERM
  }
}

final class NamespaceCommandGate: @unchecked Sendable {
  private let lock = NSLock()
  private var owners: Set<Namespace.ID> = []
  private var queued: [Namespace.ID: Int] = [:]

  func acquire(_ namespaceID: Namespace.ID) async throws {
    var isQueued = false
    defer {
      if isQueued {
        lock.withLock {
          let remaining = (queued[namespaceID] ?? 1) - 1
          queued[namespaceID] = remaining == 0 ? nil : remaining
        }
      }
    }

    while true {
      try Task.checkCancellation()
      let acquired = lock.withLock {
        if !owners.contains(namespaceID) {
          owners.insert(namespaceID)
          return true
        }
        if !isQueued {
          queued[namespaceID, default: 0] += 1
          isQueued = true
        }
        return false
      }
      if acquired {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func release(_ namespaceID: Namespace.ID) {
    _ = lock.withLock {
      owners.remove(namespaceID)
    }
  }

  func waitUntilQueued(
    _ namespaceID: Namespace.ID,
    timeout: Duration
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if lock.withLock({ (queued[namespaceID] ?? 0) > 0 }) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
}

private struct ProcessCredentialBrokerSession: NamespaceCredentialBrokerSessionHandle {
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

  func configureGitHubApp(appID: Int64, privateKeyFileURL: URL) async throws {
    try await launcher.configureGitHubApp(
      appID: appID,
      privateKeyFileURL: privateKeyFileURL,
      namespaceID: namespaceID,
      generation: generation
    )
  }

  func listGitHubInstallations() async throws -> [GitHubInstallationDescriptor] {
    try await launcher.listGitHubInstallations(
      namespaceID: namespaceID,
      generation: generation
    )
  }

  func listGitHubRepositories(
    installationID: Int64
  ) async throws -> [GitHubRepositoryDescriptor] {
    try await launcher.listGitHubRepositories(
      installationID: installationID,
      namespaceID: namespaceID,
      generation: generation
    )
  }

  func authorizeGitHubRepository(_ authorization: GitHubRepositoryAuthorization) async throws {
    try await launcher.authorizeGitHubRepository(
      authorization,
      namespaceID: namespaceID,
      generation: generation
    )
  }

  func performGitHubIssueRequest(
    _ request: GitHubIssueCapabilityRequest
  ) async throws -> GitHubIssueCapabilityResponse {
    try await launcher.performGitHubIssueRequest(
      request,
      namespaceID: namespaceID,
      generation: generation
    )
  }

  func performGitHubGitOperation(
    _ request: GitRepositoryCapabilityRequest
  ) async throws -> GitRepositoryCapabilityResult {
    try await launcher.performGitHubGitOperation(
      request,
      namespaceID: namespaceID,
      generation: generation
    )
  }
}

public struct GitHubCapabilityError: LocalizedError, Equatable, Sendable {
  public let failure: GitHubCapabilityFailure

  public init(_ failure: GitHubCapabilityFailure) {
    self.failure = failure
  }

  public var errorDescription: String? { failure.message }
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
  enum Context {
    case handshake
    case capability
  }

  static func readLine(
    from descriptor: Int32,
    timeout: TimeInterval,
    maximumBytes: Int = 16_384,
    context: Context = .handshake,
    cancellation: BrokerReadCancellation? = nil
  ) throws -> Data {
    let clock = ContinuousClock()
    let timeoutMilliseconds = max(Int64(1), Int64((timeout * 1_000).rounded(.up)))
    let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    var accumulated = Data()

    while clock.now < deadline {
      if cancellation?.isCancelled == true {
        throw CredentialBrokerProcessError.capabilityUnavailable
      }
      let remaining = clock.now.duration(to: deadline).components
      let remainingMilliseconds =
        Double(remaining.seconds) * 1_000
        + Double(remaining.attoseconds) / 1_000_000_000_000_000
      let pollTimeout = Int32(max(1, min(remainingMilliseconds.rounded(.up), 50)))
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let result = Darwin.poll(&pollDescriptor, 1, pollTimeout)
      if result == 0 {
        continue
      }
      if result < 0 {
        if errno == EINTR { continue }
        throw failure(for: context)
      }

      var buffer = [UInt8](repeating: 0, count: 1_024)
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count <= 0 {
        throw failure(for: context)
      }
      accumulated.append(contentsOf: buffer.prefix(count))
      if let newline = accumulated.firstIndex(of: 0x0A) {
        guard newline <= maximumBytes else {
          switch context {
          case .handshake:
            throw CredentialBrokerProcessError.handshakeFailed
          case .capability:
            throw CredentialBrokerProcessError.capabilityResponseTooLarge
          }
        }
        return accumulated[..<newline]
      }
      guard accumulated.count <= maximumBytes else {
        switch context {
        case .handshake:
          throw CredentialBrokerProcessError.handshakeFailed
        case .capability:
          throw CredentialBrokerProcessError.capabilityResponseTooLarge
        }
      }
    }
    switch context {
    case .handshake:
      throw CredentialBrokerProcessError.handshakeTimedOut
    case .capability:
      throw CredentialBrokerProcessError.capabilityTimedOut
    }
  }

  private static func failure(for context: Context) -> CredentialBrokerProcessError {
    switch context {
    case .handshake: .handshakeFailed
    case .capability: .invalidCapabilityResponse
    }
  }
}

private final class BrokerReadCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() { lock.withLock { cancelled = true } }
}

public enum CredentialBrokerProcessError: LocalizedError, Sendable {
  case executableNotFound
  case executableNotExecutable(URL)
  case sessionAlreadyRunning
  case sessionNotRunning
  case requestTooLarge
  case capabilityUnavailable
  case pipeConfigurationFailed
  case capabilityFailed(String)
  case invalidCapabilityResponse
  case capabilityResponseTooLarge
  case capabilityTimedOut
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
    case .capabilityUnavailable:
      "This credential broker does not support the requested GitHub capability."
    case .pipeConfigurationFailed:
      "The credential broker pipe could not be configured safely."
    case .capabilityFailed(let message):
      message
    case .invalidCapabilityResponse:
      "The credential broker returned an invalid capability response. Lock the namespace and try again."
    case .capabilityResponseTooLarge:
      "The credential broker response exceeded the safe limit. Narrow the GitHub App installation and try again."
    case .capabilityTimedOut:
      "The credential broker operation timed out. Try again."
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
