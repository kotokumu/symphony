import Darwin
import Foundation
import SymphonyCredentialBrokerProtocol

final class OperationCredential: @unchecked Sendable {
  let buffer: SecureSecretBuffer
  private let lock = NSLock()
  private var cleared = false

  init(copying source: SecureSecretBuffer) {
    buffer = source.withTemporaryData { SecureSecretBuffer(copying: $0) }
  }

  deinit { clear() }

  func clear() {
    lock.withLock {
      guard !cleared else { return }
      cleared = true
      buffer.clear()
    }
  }

  func redact(_ value: String) -> String {
    buffer.withTemporaryData { data in
      let token = String(decoding: data, as: UTF8.self)
      let representations = [
        token,
        data.base64EncodedString(),
        data.map { String(format: "%02x", $0) }.joined(),
        Data("x-access-token:\(token)".utf8).base64EncodedString(),
        "Bearer \(token)",
        "Basic \(Data("x-access-token:\(token)".utf8).base64EncodedString())",
      ].filter { !$0.isEmpty }
      return representations.reduce(value) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") }
    }
  }
}

protocol ScopedGitRunning: Sendable {
  func run(
    _ request: GitRepositoryCapabilityRequest,
    in scope: AuthorizedGitHubRepositoryScope,
    acquireCredential: @escaping @Sendable () async throws -> OperationCredential
  ) async throws -> GitRepositoryCapabilityResult
  func stopRetainedOperation() async throws
}

final class ScopedGitCommandRunner: ScopedGitRunning, @unchecked Sendable {
  private struct RetainedRuntime {
    let process: GitProcessReference
    let server: PrivateGitCredentialServer
    let credential: OperationCredential
    let temporaryDirectory: URL
  }

  private let policy: GitRepositoryTrustPolicy
  private let gitExecutableURL: URL
  private let brokerExecutableURL: URL
  private let operationTimeout: TimeInterval
  private let stopTimeout: TimeInterval
  private let wrapsGitInBrokerExecutable: Bool
  private let lock = NSLock()
  private var active: RetainedRuntime?
  private var retained: RetainedRuntime?
  private var operationInProgress = false
  private var stopRequested = false

  init(
    policy: GitRepositoryTrustPolicy = GitRepositoryTrustPolicy(),
    gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
    brokerExecutableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
    operationTimeout: TimeInterval = 300,
    stopTimeout: TimeInterval = 0.75,
    wrapsGitInBrokerExecutable: Bool = true
  ) {
    self.policy = policy
    self.gitExecutableURL = gitExecutableURL
    self.brokerExecutableURL = brokerExecutableURL
    self.operationTimeout = operationTimeout
    self.stopTimeout = stopTimeout
    self.wrapsGitInBrokerExecutable = wrapsGitInBrokerExecutable
  }

  func run(
    _ request: GitRepositoryCapabilityRequest,
    in scope: AuthorizedGitHubRepositoryScope,
    acquireCredential: @escaping @Sendable () async throws -> OperationCredential
  ) async throws -> GitRepositoryCapabilityResult {
    guard lock.withLock({
      guard retained == nil, active == nil, !operationInProgress else { return false }
      operationInProgress = true
      stopRequested = false
      return true
    }) else {
      throw GitCommandRunnerError.cleanupRequired
    }
    defer {
      lock.withLock {
        operationInProgress = false
        if retained == nil { stopRequested = false }
      }
    }
    let plan = try policy.validate(request, in: scope)
    try requireAdmission()
    let credential = try await acquireCredential()
    do {
      try requireAdmission()
      try policy.revalidate(plan, in: scope)
    } catch {
      credential.clear()
      throw error
    }

    let server = try PrivateGitCredentialServer(scope: scope, credential: credential)
    let serverTask = Task.detached { server.serve() }
    let process = Process()
    let output = Pipe()
    let arguments = gitArguments(plan.arguments)
    process.executableURL = wrapsGitInBrokerExecutable ? brokerExecutableURL : gitExecutableURL
    process.arguments = wrapsGitInBrokerExecutable
      ? ["git-runner", gitExecutableURL.path] + arguments
      : arguments
    let isolated = try isolatedEnvironment(server: server)
    process.environment = isolated.environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
    } catch {
      server.stop()
      _ = await serverTask.value
      credential.clear()
      try? FileManager.default.removeItem(at: isolated.temporaryDirectory)
      throw GitCommandRunnerError.launchFailed
    }
    let processReference = GitProcessReference(process)
    let ownedRuntime = RetainedRuntime(
      process: processReference,
      server: server,
      credential: credential,
      temporaryDirectory: isolated.temporaryDirectory
    )
    lock.withLock { active = ownedRuntime }
    let collector = GitOutputCollector(
      handle: output.fileHandleForReading,
      maximumBytes: CredentialBrokerProtocolLimits.maximumGitOutputBytes
    )
    let reader = Task.detached { collector.readToEnd() }
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(operationTimeout * 1_000)))
    var timedOut = false
    while processReference.isRunning, ContinuousClock.now < deadline, !collector.exceededLimit {
      if Task.isCancelled { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
    if processReference.isRunning {
      timedOut = ContinuousClock.now >= deadline
      do {
        try await stop(processReference)
      } catch {
        lock.withLock {
          active = nil
          retained = ownedRuntime
        }
        throw GitCommandRunnerError.cleanupRequired
      }
    }
    server.stop()
    _ = await serverTask.value
    output.fileHandleForReading.closeFile()
    _ = await reader.value
    let rawOutput = collector.prefix
    let sanitized = credential.redact(String(decoding: rawOutput, as: UTF8.self))
    let status = processReference.terminationStatus
    let erased = server.authenticationWasRejected
    credential.clear()
    try? FileManager.default.removeItem(at: isolated.temporaryDirectory)
    lock.withLock { active = nil }

    if collector.exceededLimit || timedOut || Task.isCancelled || erased || status != 0 {
      try cleanupFailedClone(plan, scope: scope)
    }
    if collector.exceededLimit { throw GitCommandRunnerError.outputTooLarge(sanitized) }
    if timedOut || Task.isCancelled { throw GitCommandRunnerError.timedOut }
    if erased { throw GitCommandRunnerError.authenticationRejected }
    guard status == 0 else { throw GitCommandRunnerError.failed(status, sanitized) }
    return GitRepositoryCapabilityResult(
      exitStatus: status,
      output: sanitized,
      wasTruncated: false
    )
  }

  func stopRetainedOperation() async throws {
    let runtime = lock.withLock { () -> RetainedRuntime? in
      stopRequested = true
      return retained ?? active
    }
    if let runtime {
      try await stop(runtime.process)
      runtime.server.stop()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while lock.withLock({ operationInProgress }), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    guard !lock.withLock({ operationInProgress }) else {
      throw GitCommandRunnerError.cleanupRequired
    }
    if let retained = lock.withLock({ self.retained }) {
      guard !retained.process.isRunning else { throw GitCommandRunnerError.cleanupRequired }
      retained.server.stop()
      retained.credential.clear()
      try? FileManager.default.removeItem(at: retained.temporaryDirectory)
    }
    lock.withLock {
      active = nil
      retained = nil
      stopRequested = false
    }
  }

  func waitUntilStopRequested(timeout: Duration = .seconds(1)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if lock.withLock({ stopRequested }) { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  private func gitArguments(_ operationArguments: [String]) -> [String] {
    let helper = shellQuote(brokerExecutableURL.path)
    return [
      "-c", "credential.helper=",
      "-c", "credential.helper=!\(helper) git-credential",
      "-c", "credential.useHttpPath=true",
      "-c", "http.followRedirects=false",
      "-c", "core.hooksPath=/dev/null",
    ] + operationArguments
  }

  private func isolatedEnvironment(
    server: PrivateGitCredentialServer
  ) throws -> (environment: [String: String], temporaryDirectory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-git-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    guard chmod(directory.path, S_IRWXU) == 0 else { throw GitCommandRunnerError.launchFailed }
    return ([
      "PATH": "/usr/bin:/bin",
      "HOME": directory.path,
      "TMPDIR": directory.path,
      "LANG": "C",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_TERMINAL_PROMPT": "0",
      "GIT_ASKPASS": "/usr/bin/false",
      "SYMPHONY_GIT_HELPER_PORT": String(server.port),
      "SYMPHONY_GIT_HELPER_NONCE": server.nonce,
    ], directory)
  }

  private func stop(_ process: GitProcessReference) async throws {
    guard process.isRunning else { return }
    process.terminateGroup(SIGTERM)
    if await waitForExit(process, timeout: stopTimeout) { return }
    process.terminateGroup(SIGKILL)
    guard await waitForExit(process, timeout: stopTimeout) else {
      throw GitCommandRunnerError.cleanupRequired
    }
  }

  private func waitForExit(_ process: GitProcessReference, timeout: TimeInterval) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeout * 1_000)))
    while process.isRunning, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return !process.isRunning
  }

  private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func requireAdmission() throws {
    guard !lock.withLock({ stopRequested }) else { throw CancellationError() }
  }

  private func cleanupFailedClone(
    _ plan: ValidatedGitOperationPlan,
    scope: AuthorizedGitHubRepositoryScope
  ) throws {
    guard case .clone = plan.request,
      FileManager.default.fileExists(atPath: plan.targetURL.path)
    else { return }
    var root = stat()
    var target = stat()
    guard lstat(scope.workspacesRoot.path, &root) == 0,
      FileIdentity(device: UInt64(root.st_dev), inode: UInt64(root.st_ino)) == plan.rootIdentity,
      lstat(plan.targetURL.path, &target) == 0,
      target.st_mode & S_IFMT == S_IFDIR,
      plan.targetURL.deletingLastPathComponent().standardizedFileURL == scope.workspacesRoot
    else { throw GitCommandRunnerError.cleanupRequired }
    do {
      try FileManager.default.removeItem(at: plan.targetURL)
    } catch {
      throw GitCommandRunnerError.cleanupRequired
    }
  }
}

private final class GitProcessReference: @unchecked Sendable {
  private let process: Process
  init(_ process: Process) { self.process = process }
  var isRunning: Bool { process.isRunning }
  var terminationStatus: Int32 { process.terminationStatus }
  func terminateGroup(_ signal: Int32) {
    if Darwin.kill(-process.processIdentifier, signal) != 0 {
      _ = Darwin.kill(process.processIdentifier, signal)
    }
  }
}

private final class GitOutputCollector: @unchecked Sendable {
  private let handle: FileHandle
  private let maximumBytes: Int
  private let lock = NSLock()
  private var data = Data()
  private var exceeded = false

  init(handle: FileHandle, maximumBytes: Int) {
    self.handle = handle
    self.maximumBytes = maximumBytes
  }

  var exceededLimit: Bool { lock.withLock { exceeded } }
  var prefix: Data { lock.withLock { data } }

  func readToEnd() {
    while let chunk = try? handle.read(upToCount: 4_096), !chunk.isEmpty {
      lock.withLock {
        let originalCount = data.count
        if data.count < maximumBytes {
          data.append(chunk.prefix(maximumBytes - data.count))
        }
        if originalCount > maximumBytes - min(chunk.count, maximumBytes) {
          exceeded = true
        }
      }
    }
  }
}

enum GitCommandRunnerError: LocalizedError, Sendable {
  case launchFailed, timedOut, cleanupRequired, authenticationRejected
  case outputTooLarge(String), failed(Int32, String)

  var failure: GitHubCapabilityFailure {
    switch self {
    case .launchFailed:
      GitHubCapabilityFailure(category: .gitFailed, message: "Git could not start safely.")
    case .timedOut:
      GitHubCapabilityFailure(category: .timedOut, message: "Git did not finish within five minutes.")
    case .cleanupRequired:
      GitHubCapabilityFailure(
        category: .cleanupRequired,
        message: "Git cleanup is incomplete. Lock this namespace before retrying."
      )
    case .authenticationRejected:
      GitHubCapabilityFailure(
        category: .gitAuthenticationRejected,
        message: "GitHub rejected the Git credential. Retry once to refresh it."
      )
    case .outputTooLarge(let output):
      GitHubCapabilityFailure(
        category: .gitOutputTooLarge,
        message: "Git produced too much output. \(output)"
      )
    case .failed(let status, let output):
      GitHubCapabilityFailure(
        category: .gitFailed,
        message: "Git exited with status \(status). \(output)"
      )
    }
  }

  var errorDescription: String? { failure.message }
}

private struct GitCredentialWireRequest: Codable {
  let nonce: String
  let action: String
  let input: Data
}

private struct GitCredentialWireResponse: Codable {
  let succeeded: Bool
  let output: Data
}

final class PrivateGitCredentialServer: @unchecked Sendable {
  let port: UInt16
  let nonce: String
  private let descriptor: Int32
  private let scope: AuthorizedGitHubRepositoryScope
  private let credential: OperationCredential
  private let stateLock = NSLock()
  private var stopped = false
  private var rejected = false

  init(scope: AuthorizedGitHubRepositoryScope, credential: OperationCredential) throws {
    self.scope = scope
    self.credential = credential
    nonce = UUID().uuidString + UUID().uuidString
    let listeningDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard listeningDescriptor >= 0 else { throw GitCommandRunnerError.launchFailed }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listeningDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, Darwin.listen(listeningDescriptor, 8) == 0 else {
      Darwin.close(listeningDescriptor)
      throw GitCommandRunnerError.launchFailed
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.getsockname(listeningDescriptor, $0, &length)
      }
    }
    guard named == 0 else {
      Darwin.close(listeningDescriptor)
      throw GitCommandRunnerError.launchFailed
    }
    descriptor = listeningDescriptor
    port = UInt16(bigEndian: actual.sin_port)
  }

  var authenticationWasRejected: Bool { stateLock.withLock { rejected } }

  func serve() {
    while !stateLock.withLock({ stopped }) {
      let client = Darwin.accept(descriptor, nil, nil)
      if client < 0 { break }
      defer { Darwin.close(client) }
      do {
        let data = try SocketLine.read(client, maximumBytes: 32_768, timeoutMilliseconds: 5_000)
        let request = try JSONDecoder().decode(GitCredentialWireRequest.self, from: data)
        guard request.nonce == nonce else { throw GitCommandRunnerError.authenticationRejected }
        let response = try conversation(action: request.action, input: request.input)
        try SocketLine.write(JSONEncoder().encode(response), to: client)
      } catch {
        let response = GitCredentialWireResponse(succeeded: false, output: Data())
        try? SocketLine.write(JSONEncoder().encode(response), to: client)
      }
    }
  }

  func stop() {
    stateLock.withLock {
      guard !stopped else { return }
      stopped = true
      Darwin.shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
    }
  }

  private func conversation(action: String, input: Data) throws -> GitCredentialWireResponse {
    guard input.count <= CredentialBrokerProtocolLimits.maximumGitCredentialInputBytes else {
      return GitCredentialWireResponse(succeeded: false, output: Data())
    }
    if action == "store" { return GitCredentialWireResponse(succeeded: true, output: Data()) }
    if action == "erase" {
      stateLock.withLock { rejected = true }
      return GitCredentialWireResponse(succeeded: true, output: Data())
    }
    guard action == "get", let values = GitCredentialInput(input), values.matches(scope) else {
      return GitCredentialWireResponse(succeeded: false, output: Data())
    }
    let output = credential.buffer.withTemporaryData { token in
      var data = Data("username=x-access-token\npassword=".utf8)
      data.append(token)
      data.append(Data("\n\n".utf8))
      return data
    }
    return GitCredentialWireResponse(succeeded: true, output: output)
  }
}

private struct GitCredentialInput {
  let values: [String: String]

  init?(_ data: Data) {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var values: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      guard let separator = line.firstIndex(of: "=") else { return nil }
      let key = String(line[..<separator])
      guard values[key] == nil else { return nil }
      values[key] = String(line[line.index(after: separator)...])
    }
    self.values = values
  }

  func matches(_ scope: AuthorizedGitHubRepositoryScope) -> Bool {
    guard values["protocol"]?.lowercased() == "https",
      values["host"]?.lowercased() == "github.com",
      let path = values["path"],
      !path.contains("%")
    else { return false }
    var trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    if trimmed.lowercased().hasSuffix(".git") { trimmed.removeLast(4) }
    guard let identity = try? GitHubRepositoryIdentity(fullName: trimmed) else { return false }
    return identity.owner.lowercased() == scope.owner.lowercased()
      && identity.repository.lowercased() == scope.repository.lowercased()
  }
}

public enum BrokerGitCredentialHelper {
  public static func run(
    action: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Int32 {
    guard let input = try? FileHandle.standardInput.read(
      upToCount: CredentialBrokerProtocolLimits.maximumGitCredentialInputBytes + 1
    ) else { return 1 }
    let result = exchange(action: action, input: input, environment: environment)
    if result.status == 0 { FileHandle.standardOutput.write(result.output) }
    return result.status
  }

  static func exchange(
    action: String,
    input: Data,
    environment: [String: String]
  ) -> (status: Int32, output: Data) {
    guard ["get", "store", "erase"].contains(action),
      let portText = environment["SYMPHONY_GIT_HELPER_PORT"],
      let port = UInt16(portText),
      let nonce = environment["SYMPHONY_GIT_HELPER_NONCE"],
      input.count <= CredentialBrokerProtocolLimits.maximumGitCredentialInputBytes
    else { return (1, Data()) }
    do {
      let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
      guard descriptor >= 0 else { return (1, Data()) }
      defer { Darwin.close(descriptor) }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard connected == 0 else { return (1, Data()) }
      let request = GitCredentialWireRequest(nonce: nonce, action: action, input: input)
      try SocketLine.write(JSONEncoder().encode(request), to: descriptor)
      let responseData = try SocketLine.read(
        descriptor,
        maximumBytes: 32_768,
        timeoutMilliseconds: 5_000
      )
      let response = try JSONDecoder().decode(GitCredentialWireResponse.self, from: responseData)
      guard response.succeeded else { return (1, Data()) }
      return (0, response.output)
    } catch {
      return (1, Data())
    }
  }
}

private enum SocketLine {
  static func read(_ descriptor: Int32, maximumBytes: Int, timeoutMilliseconds: Int32) throws -> Data {
    var data = Data()
    while data.count <= maximumBytes {
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      guard Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds) > 0 else {
        throw GitCommandRunnerError.timedOut
      }
      var byte: UInt8 = 0
      guard Darwin.recv(descriptor, &byte, 1, 0) == 1 else {
        throw GitCommandRunnerError.authenticationRejected
      }
      if byte == 0x0A { return data }
      data.append(byte)
    }
    throw GitCommandRunnerError.outputTooLarge("")
  }

  static func write(_ data: Data, to descriptor: Int32) throws {
    var framed = data
    framed.append(0x0A)
    try framed.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
        guard written > 0 else { throw GitCommandRunnerError.authenticationRejected }
        offset += written
      }
    }
  }
}
