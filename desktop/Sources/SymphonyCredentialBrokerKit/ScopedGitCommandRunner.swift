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
    let proxy: GitHubConnectProxy?
    let credential: OperationCredential
    let temporaryDirectory: URL
    let plan: ValidatedGitOperationPlan
    let cloneTarget: CloneTargetHandle?
    let authority: GitExecutionAuthority
    let scope: AuthorizedGitHubRepositoryScope
  }

  private struct PendingCloneCleanup {
    let plan: ValidatedGitOperationPlan
    let target: CloneTargetHandle
    let scope: AuthorizedGitHubRepositoryScope
    let temporaryDirectory: URL
  }

  private let policy: GitRepositoryTrustPolicy
  private let gitExecutableURL: URL
  private let brokerExecutableURL: URL
  private let sandboxExecutableURL: URL
  private let operationTimeout: TimeInterval
  private let stopTimeout: TimeInterval
  private let wrapsGitInBrokerExecutable: Bool
  private let beforeLaunch: @Sendable () async -> Void
  private let beforeCloneCleanup: @Sendable () -> Void
  private let beforeCloneTargetOpen: @Sendable (Int32, String) -> Void
  private let afterExecutionAuthorityPrepared: @Sendable (URL) -> Void
  private let beforeNestedCloneCleanup: @Sendable (Int32, String) -> Void
  private let beforeClonePublish: @Sendable (Int32, String) -> Void
  private let afterClonePublish: @Sendable (Int32, String) -> Void
  private let beforeDestructiveCloneCleanup: @Sendable (Int32, String) -> Void
  private let afterProcessGroupEstablished: @Sendable (Int32) -> Void
  private let processGroupController: GitProcessGroupController
  private let lock = NSLock()
  private var active: RetainedRuntime?
  private var retained: RetainedRuntime?
  private var pendingCloneCleanup: PendingCloneCleanup?
  private var operationInProgress = false
  private var stopRequested = false

  init(
    policy: GitRepositoryTrustPolicy = GitRepositoryTrustPolicy(),
    gitExecutableURL: URL = TrustedSystemGitExecutable.locate()
      ?? URL(fileURLWithPath: "/nonexistent/symphony-git"),
    brokerExecutableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
    sandboxExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
    operationTimeout: TimeInterval = 300,
    stopTimeout: TimeInterval = 0.4,
    wrapsGitInBrokerExecutable: Bool = true,
    beforeLaunch: @escaping @Sendable () async -> Void = {},
    beforeCloneCleanup: @escaping @Sendable () -> Void = {},
    beforeCloneTargetOpen: @escaping @Sendable (Int32, String) -> Void = { _, _ in },
    afterExecutionAuthorityPrepared: @escaping @Sendable (URL) -> Void = { _ in },
    beforeNestedCloneCleanup: @escaping @Sendable (Int32, String) -> Void = { _, _ in },
    beforeClonePublish: @escaping @Sendable (Int32, String) -> Void = { _, _ in },
    afterClonePublish: @escaping @Sendable (Int32, String) -> Void = { _, _ in },
    beforeDestructiveCloneCleanup: @escaping @Sendable (Int32, String) -> Void = { _, _ in },
    afterProcessGroupEstablished: @escaping @Sendable (Int32) -> Void = { _ in },
    processGroupController: GitProcessGroupController = .system
  ) {
    self.policy = policy
    self.gitExecutableURL = gitExecutableURL
    self.brokerExecutableURL = brokerExecutableURL
    self.sandboxExecutableURL = sandboxExecutableURL
    self.operationTimeout = operationTimeout
    self.stopTimeout = stopTimeout
    self.wrapsGitInBrokerExecutable = wrapsGitInBrokerExecutable
    self.beforeLaunch = beforeLaunch
    self.beforeCloneCleanup = beforeCloneCleanup
    self.beforeCloneTargetOpen = beforeCloneTargetOpen
    self.afterExecutionAuthorityPrepared = afterExecutionAuthorityPrepared
    self.beforeNestedCloneCleanup = beforeNestedCloneCleanup
    self.beforeClonePublish = beforeClonePublish
    self.afterClonePublish = afterClonePublish
    self.beforeDestructiveCloneCleanup = beforeDestructiveCloneCleanup
    self.afterProcessGroupEstablished = afterProcessGroupEstablished
    self.processGroupController = processGroupController
  }

  func run(
    _ request: GitRepositoryCapabilityRequest,
    in scope: AuthorizedGitHubRepositoryScope,
    acquireCredential: @escaping @Sendable () async throws -> OperationCredential
  ) async throws -> GitRepositoryCapabilityResult {
    guard lock.withLock({
      guard retained == nil, active == nil, pendingCloneCleanup == nil, !operationInProgress else {
        return false
      }
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
    guard Darwin.access(gitExecutableURL.path, X_OK) == 0 else {
      throw GitCommandRunnerError.launchFailed
    }
    try requireNoOrphanedCloneResidue(in: scope.workspacesRoot)
    try requireAdmission()
    let isolated: (environment: [String: String], temporaryDirectory: URL)
    do {
      isolated = try isolatedEnvironment()
    } catch {
      throw error
    }
    let cloneTarget: CloneTargetHandle?
    do {
      cloneTarget = try prepareCloneTarget(plan)
    } catch let error as CloneTargetPreparationError {
      switch error {
      case .replaced(let target):
        lock.withLock {
          pendingCloneCleanup = PendingCloneCleanup(
            plan: plan,
            target: target,
            scope: scope,
            temporaryDirectory: isolated.temporaryDirectory
          )
        }
      }
      throw GitCommandRunnerError.cleanupRequired
    } catch {
      removeIsolatedDirectory(isolated.temporaryDirectory)
      throw error
    }
    await beforeLaunch()
    do {
      try requireAdmission()
      try policy.revalidate(
        plan,
        in: scope,
        preparedCloneIdentity: cloneTarget?.identity,
        preparedCloneURL: cloneTarget.map { plan.targetURL.deletingLastPathComponent().appendingPathComponent($0.currentEntryName) }
      )
    } catch {
      try cleanupPreparedCloneOrRetain(
        plan,
        target: cloneTarget,
        scope: scope,
        temporaryDirectory: isolated.temporaryDirectory
      )
      removeIsolatedDirectory(isolated.temporaryDirectory)
      throw error
    }
    var acquiredCredential: OperationCredential?
    do {
      acquiredCredential = try await acquireCredential()
      try requireAdmission()
      try policy.revalidate(
        plan,
        in: scope,
        preparedCloneIdentity: cloneTarget?.identity,
        preparedCloneURL: cloneTarget.map { plan.targetURL.deletingLastPathComponent().appendingPathComponent($0.currentEntryName) }
      )
    } catch {
      acquiredCredential?.clear()
      try cleanupPreparedCloneOrRetain(
        plan,
        target: cloneTarget,
        scope: scope,
        temporaryDirectory: isolated.temporaryDirectory
      )
      removeIsolatedDirectory(isolated.temporaryDirectory)
      throw error
    }
    guard let credential = acquiredCredential else { throw GitCommandRunnerError.launchFailed }
    let authority: GitExecutionAuthority
    do {
      authority = try prepareExecutionAuthority(plan, cloneTarget: cloneTarget)
      afterExecutionAuthorityPrepared(authority.writeRoot)
      try requireAdmission()
      if let cloneTarget {
        try policy.revalidate(
          plan,
          in: scope,
          preparedCloneIdentity: cloneTarget.identity,
          preparedCloneURL: plan.targetURL.deletingLastPathComponent()
            .appendingPathComponent(cloneTarget.currentEntryName)
        )
      }
    } catch {
      credential.clear()
      try cleanupPreparedCloneOrRetain(
        plan,
        target: cloneTarget,
        scope: scope,
        temporaryDirectory: isolated.temporaryDirectory
      )
      removeIsolatedDirectory(isolated.temporaryDirectory)
      throw error
    }
    let server: PrivateGitCredentialServer
    do {
      server = try PrivateGitCredentialServer(scope: scope, credential: credential)
    } catch {
      credential.clear()
      try cleanupPreparedCloneOrRetain(
        plan,
        target: cloneTarget,
        scope: scope,
        temporaryDirectory: isolated.temporaryDirectory
      )
      removeIsolatedDirectory(isolated.temporaryDirectory)
      throw error
    }
    let serverTask = Task.detached { server.serve() }
    let proxy: GitHubConnectProxy?
    do {
      proxy = wrapsGitInBrokerExecutable ? try GitHubConnectProxy() : nil
    } catch {
      server.stop()
      _ = await serverTask.value
      credential.clear()
      try cleanupPreparedCloneOrRetain(
        plan,
        target: cloneTarget,
        scope: scope,
        temporaryDirectory: isolated.temporaryDirectory
      )
      removeIsolatedDirectory(isolated.temporaryDirectory)
      throw GitCommandRunnerError.launchFailed
    }
    let process = Process()
    let output = Pipe()
    let arguments = gitArguments(
      wrapsGitInBrokerExecutable
        ? authority.arguments
        : unsandboxedOperationArguments(plan, cloneTarget: cloneTarget),
      repositoryURL: scope.repositoryURL,
      proxyPort: proxy?.port
    )
    process.executableURL = wrapsGitInBrokerExecutable ? sandboxExecutableURL : gitExecutableURL
    process.arguments = wrapsGitInBrokerExecutable
      ? sandboxArguments(
        authority: authority,
        temporaryDirectory: isolated.temporaryDirectory,
        proxyPort: proxy!.port
      )
        + [brokerExecutableURL.path, "git-runner", gitExecutableURL.path] + arguments
      : arguments
    var processEnvironment = isolated.environment
    if wrapsGitInBrokerExecutable { processEnvironment["SYMPHONY_GIT_AUTHORITY_FD"] = "2" }
    process.environment = processEnvironment
    process.standardInput = server.clientHandle
    process.standardOutput = output
    process.standardError = wrapsGitInBrokerExecutable
      ? FileHandle(fileDescriptor: authority.descriptor, closeOnDealloc: false)
      : output
    var launchedProcessID: Int32?
    var ownsProcessGroup = false
    do {
      try process.run()
      launchedProcessID = process.processIdentifier
      if !wrapsGitInBrokerExecutable {
        ownsProcessGroup = Darwin.setpgid(
          process.processIdentifier,
          process.processIdentifier
        ) == 0 || Darwin.getpgid(process.processIdentifier) == process.processIdentifier
      } else {
        guard waitForProcessGroup(process.processIdentifier) else {
          throw GitCommandRunnerError.launchFailed
        }
        ownsProcessGroup = true
      }
      if ownsProcessGroup { afterProcessGroupEstablished(process.processIdentifier) }
      server.closeClientCopy()
    } catch {
      if let launchedProcessID { _ = Darwin.kill(launchedProcessID, SIGKILL) }
      proxy?.stop()
      server.stop()
      _ = await serverTask.value
      credential.clear()
      try cleanupPreparedCloneOrRetain(
        plan,
        target: cloneTarget,
        scope: scope,
        temporaryDirectory: isolated.temporaryDirectory
      )
      removeIsolatedDirectory(isolated.temporaryDirectory)
      throw GitCommandRunnerError.launchFailed
    }
    let processReference = GitProcessReference(
      process,
      ownsProcessGroup: ownsProcessGroup,
      controller: processGroupController
    )
    let ownedRuntime = RetainedRuntime(
      process: processReference,
      server: server,
      proxy: proxy,
      credential: credential,
      temporaryDirectory: isolated.temporaryDirectory,
      plan: plan,
      cloneTarget: cloneTarget,
      authority: authority,
      scope: scope
    )
    let stopAfterLaunch = lock.withLock { () -> Bool in
      active = ownedRuntime
      return stopRequested
    }
    if stopAfterLaunch {
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
    let collector = GitOutputCollector(
      handle: output.fileHandleForReading,
      maximumBytes: CredentialBrokerProtocolLimits.maximumGitOutputBytes
    )
    let reader = Task.detached { collector.readToEnd() }
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(operationTimeout * 1_000)))
    var timedOut = false
    while processReference.groupExists, ContinuousClock.now < deadline, !collector.exceededLimit {
      if Task.isCancelled { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
    if processReference.groupExists {
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
    proxy?.stop()
    server.stop()
    _ = await serverTask.value
    let outputDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
    while !collector.finished, ContinuousClock.now < outputDeadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
    output.fileHandleForReading.closeFile()
    if collector.finished {
      _ = await reader.value
    } else {
      reader.cancel()
    }
    let rawOutput = collector.prefix
    let sanitized = credential.redact(String(decoding: rawOutput, as: UTF8.self))
    let status = processReference.terminationStatus
    let erased = server.authenticationWasRejected
    credential.clear()
    removeIsolatedDirectory(isolated.temporaryDirectory)
    lock.withLock { active = nil }

    if collector.exceededLimit || timedOut || Task.isCancelled || erased || status != 0 {
      do {
        try cleanupFailedClone(plan, target: cloneTarget, scope: scope)
      } catch {
        lock.withLock { retained = ownedRuntime }
        throw error
      }
    }
    if collector.exceededLimit { throw GitCommandRunnerError.outputTooLarge(sanitized) }
    if timedOut || Task.isCancelled { throw GitCommandRunnerError.timedOutWithOutput(sanitized) }
    if erased { throw GitCommandRunnerError.authenticationRejected }
    guard status == 0 else { throw GitCommandRunnerError.failed(status, sanitized) }
    if let cloneTarget {
      do {
        try publishClone(plan, target: cloneTarget, scope: scope)
      } catch {
        do {
          try cleanupFailedClone(plan, target: cloneTarget, scope: scope)
        } catch {
          lock.withLock { retained = ownedRuntime }
        }
        throw GitCommandRunnerError.cleanupRequired
      }
    }
    return GitRepositoryCapabilityResult(
      exitStatus: status,
      output: sanitized,
      wasTruncated: false
    )
  }

  func stopRetainedOperation() async throws {
    let shutdownDeadline = ContinuousClock.now.advanced(by: .milliseconds(1_800))
    let runtime = lock.withLock { () -> RetainedRuntime? in
      stopRequested = true
      return retained ?? active
    }
    if let runtime {
      try await stop(runtime.process)
      runtime.proxy?.stop()
      runtime.server.stop()
    }
    while lock.withLock({ operationInProgress }), ContinuousClock.now < shutdownDeadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    guard !lock.withLock({ operationInProgress }) else {
      throw GitCommandRunnerError.cleanupRequired
    }
    if let pending = lock.withLock({ pendingCloneCleanup }) {
      try cleanupFailedClone(
        pending.plan,
        target: pending.target,
        scope: pending.scope,
        deadline: shutdownDeadline
      )
      removeIsolatedDirectory(pending.temporaryDirectory)
      lock.withLock { pendingCloneCleanup = nil }
    }
    if let retained = lock.withLock({ self.retained }) {
      guard !retained.process.groupExists else { throw GitCommandRunnerError.cleanupRequired }
      retained.server.stop()
      retained.proxy?.stop()
      retained.credential.clear()
      try cleanupFailedClone(
        retained.plan,
        target: retained.cloneTarget,
        scope: retained.scope,
        deadline: shutdownDeadline
      )
      removeIsolatedDirectory(retained.temporaryDirectory)
    }
    lock.withLock {
      active = nil
      retained = nil
      pendingCloneCleanup = nil
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

  private func gitArguments(
    _ operationArguments: [String],
    repositoryURL: URL,
    proxyPort: UInt16?
  ) -> [String] {
    let helper = shellQuote(brokerExecutableURL.path)
    let repositoryHTTPKey = "http.\(repositoryURL.absoluteString)"
    let proxy = proxyPort.map { "http://127.0.0.1:\($0)" } ?? ""
    return [
      "-c", "credential.helper=",
      "-c", "credential.helper=!\(helper) git-credential",
      "-c", "credential.useHttpPath=true",
      "-c", "http.followRedirects=false",
      "-c", "http.proxy=\(proxy)",
      "-c", "http.sslVerify=true",
      "-c", "http.extraHeader=",
      "-c", "http.cookieFile=",
      "-c", "http.saveCookies=false",
      "-c", "\(repositoryHTTPKey).proxy=\(proxy)",
      "-c", "\(repositoryHTTPKey).sslVerify=true",
      "-c", "\(repositoryHTTPKey).extraHeader=",
      "-c", "\(repositoryHTTPKey).cookieFile=",
      "-c", "protocol.allow=never",
      "-c", "protocol.https.allow=always",
      "-c", "core.hooksPath=/dev/null",
    ] + operationArguments
  }

  private func unsandboxedOperationArguments(
    _ plan: ValidatedGitOperationPlan,
    cloneTarget: CloneTargetHandle?
  ) -> [String] {
    switch plan.request {
    case .clone:
      guard let cloneTarget else { return plan.arguments }
      let stagingURL = plan.targetURL.deletingLastPathComponent()
        .appendingPathComponent(cloneTarget.currentEntryName, isDirectory: true)
      return ["clone", "--", plan.repositoryURL.absoluteString, stagingURL.path]
    case .fetch, .push:
      return plan.arguments
    }
  }

  private func prepareExecutionAuthority(
    _ plan: ValidatedGitOperationPlan,
    cloneTarget: CloneTargetHandle?
  ) throws -> GitExecutionAuthority {
    switch plan.request {
    case .clone:
      guard let cloneTarget else { throw GitCommandRunnerError.launchFailed }
      let descriptor = dup(cloneTarget.targetDescriptor)
      guard descriptor >= 0 else { throw GitCommandRunnerError.launchFailed }
      return GitExecutionAuthority(
        descriptor: descriptor,
        writeRoot: plan.targetURL.deletingLastPathComponent()
          .appendingPathComponent(cloneTarget.currentEntryName, isDirectory: true),
        arguments: ["clone", "--", plan.repositoryURL.absoluteString, "."]
      )
    case .fetch:
      return try existingRepositoryAuthority(
        plan,
        arguments: [
          "fetch", "--prune", "--", plan.repositoryURL.absoluteString,
          "+refs/heads/*:refs/remotes/origin/*",
        ]
      )
    case .push(_, let branch):
      return try existingRepositoryAuthority(
        plan,
        arguments: [
          "push", "--porcelain", "--", plan.repositoryURL.absoluteString,
          "HEAD:refs/heads/\(branch)",
        ]
      )
    }
  }

  private func existingRepositoryAuthority(
    _ plan: ValidatedGitOperationPlan,
    arguments: [String]
  ) throws -> GitExecutionAuthority {
    guard let targetIdentity = plan.targetIdentity, let metadataIdentity = plan.metadataIdentity else {
      throw GitCommandRunnerError.launchFailed
    }
    let descriptor = open(plan.targetURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw GitCommandRunnerError.launchFailed }
    var target = stat()
    guard fstat(descriptor, &target) == 0,
      FileIdentity(device: UInt64(target.st_dev), inode: UInt64(target.st_ino)) == targetIdentity
    else {
      close(descriptor)
      throw GitRepositoryTrustError.filesystemChanged
    }
    let metadataDescriptor = openat(
      descriptor,
      ".git",
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    var metadata = stat()
    guard metadataDescriptor >= 0, fstat(metadataDescriptor, &metadata) == 0,
      FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino)) == metadataIdentity
    else {
      if metadataDescriptor >= 0 { close(metadataDescriptor) }
      close(descriptor)
      throw GitRepositoryTrustError.filesystemChanged
    }
    close(metadataDescriptor)
    return GitExecutionAuthority(
      descriptor: descriptor,
      writeRoot: plan.targetURL,
      arguments: arguments
    )
  }

  private func sandboxArguments(
    authority: GitExecutionAuthority,
    temporaryDirectory: URL,
    proxyPort: UInt16
  ) -> [String] {
    [
      "-D", "WRITE_ROOT=\(authority.writeRoot.path)",
      "-D", "WRITE_ROOT_REAL=\(authority.writeRoot.resolvingSymlinksInPath().path)",
      "-D", "TEMP_ROOT=\(temporaryDirectory.path)",
      "-D", "TEMP_ROOT_REAL=\(temporaryDirectory.resolvingSymlinksInPath().path)",
      "-p", Self.sandboxProfile(proxyPort: proxyPort),
    ]
  }

  static func sandboxProfile(proxyPort: UInt16) -> String {
    """
    (version 1)
    (deny default)
    (allow process-exec process-fork)
    (allow signal (target same-sandbox))
    (allow process-info* (target same-sandbox))
    (allow file-read*)
    (allow file-ioctl)
    (allow file-write-data (require-not (vnode-type REGULAR-FILE)))
    (allow file-write*
      (literal (param "WRITE_ROOT"))
      (subpath (param "WRITE_ROOT"))
      (literal (param "WRITE_ROOT_REAL"))
      (subpath (param "WRITE_ROOT_REAL"))
      (literal (param "TEMP_ROOT"))
      (subpath (param "TEMP_ROOT"))
      (literal (param "TEMP_ROOT_REAL"))
      (subpath (param "TEMP_ROOT_REAL"))
      (literal "/dev/null"))
    (allow network* (socket-domain AF_UNIX))
    (allow network-outbound (remote tcp "localhost:\(proxyPort)"))
    (allow sysctl-read)
    (allow iokit-open (iokit-registry-entry-class "RootDomainUserClient"))
    (allow ipc-posix-sem)
    (allow ipc-posix-shm-read* (ipc-posix-name-prefix "apple.cfprefs."))
    (allow mach-lookup
      (global-name "com.apple.system.opendirectoryd.libinfo")
      (global-name "com.apple.PowerManagement.control")
      (global-name "com.apple.cfprefsd.daemon")
      (global-name "com.apple.cfprefsd.agent")
      (local-name "com.apple.cfprefsd.agent"))
    (allow user-preference-read)
    """
  }

  private func waitForProcessGroup(_ processID: Int32) -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
      if Darwin.getpgid(processID) == processID { return true }
      if Darwin.kill(processID, 0) != 0, errno != EPERM { return false }
      usleep(1_000)
    }
    return Darwin.getpgid(processID) == processID
  }

  private func isolatedEnvironment() throws -> (environment: [String: String], temporaryDirectory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-git-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    guard chmod(directory.path, S_IRWXU) == 0 else {
      try? FileManager.default.removeItem(at: directory)
      throw GitCommandRunnerError.launchFailed
    }
    return ([
      "PATH": "/usr/bin:/bin",
      "HOME": directory.path,
      "TMPDIR": directory.path,
      "LANG": "C",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_TERMINAL_PROMPT": "0",
      "GIT_ASKPASS": "/usr/bin/false",
      "NO_PROXY": "",
      "no_proxy": "",
    ], directory)
  }

  private func removeIsolatedDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
  }

  private func stop(_ process: GitProcessReference) async throws {
    guard process.groupExists else { return }
    process.terminateGroup(SIGTERM)
    if await waitForExit(process, timeout: stopTimeout) { return }
    process.terminateGroup(SIGKILL)
    guard await waitForExit(process, timeout: stopTimeout) else {
      throw GitCommandRunnerError.cleanupRequired
    }
  }

  private func waitForExit(_ process: GitProcessReference, timeout: TimeInterval) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeout * 1_000)))
    while process.groupExists, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return !process.groupExists
  }

  private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func requireAdmission() throws {
    guard !lock.withLock({ stopRequested }) else { throw CancellationError() }
  }

  private func requireNoOrphanedCloneResidue(in root: URL) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    guard names.count <= 100_000,
      !names.contains(where: {
        $0.hasPrefix(".symphony-clone-") || $0.hasPrefix(".symphony-failed-clone-")
          || $0.hasPrefix(".symphony-cleared-")
      })
    else { throw GitCommandRunnerError.cleanupRequired }
  }

  private func prepareCloneTarget(_ plan: ValidatedGitOperationPlan) throws -> CloneTargetHandle? {
    guard case .clone = plan.request else { return nil }
    let parentDescriptor = open(
      plan.targetURL.deletingLastPathComponent().path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0 else { throw GitCommandRunnerError.cleanupRequired }
    var root = stat()
    guard fstat(parentDescriptor, &root) == 0,
      FileIdentity(device: UInt64(root.st_dev), inode: UInt64(root.st_ino)) == plan.rootIdentity
    else {
      close(parentDescriptor)
      throw GitCommandRunnerError.cleanupRequired
    }
    let name = ".symphony-clone-\(UUID().uuidString)"
    guard mkdirat(parentDescriptor, name, S_IRWXU) == 0 else {
      close(parentDescriptor)
      throw GitCommandRunnerError.launchFailed
    }
    let targetDescriptor = openat(
      parentDescriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    var created = stat()
    guard targetDescriptor >= 0, fstat(targetDescriptor, &created) == 0,
      created.st_mode & S_IFMT == S_IFDIR
    else {
      if targetDescriptor >= 0 { close(targetDescriptor) }
      _ = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
      close(parentDescriptor)
      throw GitCommandRunnerError.cleanupRequired
    }
    let createdIdentity = FileIdentity(
      device: UInt64(created.st_dev),
      inode: UInt64(created.st_ino)
    )
    beforeCloneTargetOpen(parentDescriptor, name)
    var atPath = stat()
    guard fstatat(parentDescriptor, name, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
      atPath.st_mode & S_IFMT == S_IFDIR,
      FileIdentity(device: UInt64(atPath.st_dev), inode: UInt64(atPath.st_ino)) == createdIdentity
    else {
      throw CloneTargetPreparationError.replaced(
        CloneTargetHandle(
          parentDescriptor: parentDescriptor,
          targetDescriptor: targetDescriptor,
          name: name,
          identity: createdIdentity
        )
      )
    }
    return CloneTargetHandle(
      parentDescriptor: parentDescriptor,
      targetDescriptor: targetDescriptor,
      name: name,
      identity: createdIdentity
    )
  }

  private func publishClone(
    _ plan: ValidatedGitOperationPlan,
    target: CloneTargetHandle,
    scope: AuthorizedGitHubRepositoryScope
  ) throws {
    guard case .clone = plan.request,
      plan.targetURL.deletingLastPathComponent().standardizedFileURL == scope.workspacesRoot
    else { throw GitCommandRunnerError.cleanupRequired }
    var root = stat()
    var staged = stat()
    guard fstat(target.parentDescriptor, &root) == 0,
      FileIdentity(device: UInt64(root.st_dev), inode: UInt64(root.st_ino)) == plan.rootIdentity,
      fstatat(
        target.parentDescriptor,
        target.currentEntryName,
        &staged,
        AT_SYMLINK_NOFOLLOW
      ) == 0,
      staged.st_mode & S_IFMT == S_IFDIR,
      FileIdentity(device: UInt64(staged.st_dev), inode: UInt64(staged.st_ino)) == target.identity
    else { throw GitCommandRunnerError.cleanupRequired }
    beforeClonePublish(target.parentDescriptor, target.currentEntryName)
    guard fstatat(
      target.parentDescriptor,
      target.currentEntryName,
      &staged,
      AT_SYMLINK_NOFOLLOW
    ) == 0,
      staged.st_mode & S_IFMT == S_IFDIR,
      FileIdentity(device: UInt64(staged.st_dev), inode: UInt64(staged.st_ino)) == target.identity,
      renameatx_np(
        target.parentDescriptor,
        target.currentEntryName,
        target.parentDescriptor,
        plan.targetURL.lastPathComponent,
        UInt32(RENAME_EXCL)
      ) == 0
    else { throw GitCommandRunnerError.cleanupRequired }
    target.recordMove(to: plan.targetURL.lastPathComponent)
    afterClonePublish(target.parentDescriptor, target.currentEntryName)
    guard fstatat(
      target.parentDescriptor,
      target.currentEntryName,
      &staged,
      AT_SYMLINK_NOFOLLOW
    ) == 0,
      staged.st_mode & S_IFMT == S_IFDIR,
      FileIdentity(device: UInt64(staged.st_dev), inode: UInt64(staged.st_ino)) == target.identity
    else { throw GitCommandRunnerError.cleanupRequired }
  }

  private func cleanupFailedClone(
    _ plan: ValidatedGitOperationPlan,
    target: CloneTargetHandle?,
    scope: AuthorizedGitHubRepositoryScope,
    deadline suppliedDeadline: ContinuousClock.Instant? = nil
  ) throws {
    guard case .clone = plan.request, let target else { return }
    let deadline = suppliedDeadline ?? ContinuousClock.now.advanced(by: .seconds(1))
    try requireCleanupDeadline(deadline)
    let entryName = target.currentEntryName
    var root = stat()
    var targetAtPath = stat()
    guard fstat(target.parentDescriptor, &root) == 0,
      FileIdentity(device: UInt64(root.st_dev), inode: UInt64(root.st_ino)) == plan.rootIdentity,
      fstatat(target.parentDescriptor, entryName, &targetAtPath, AT_SYMLINK_NOFOLLOW) == 0,
      targetAtPath.st_mode & S_IFMT == S_IFDIR,
      FileIdentity(device: UInt64(targetAtPath.st_dev), inode: UInt64(targetAtPath.st_ino)) == target.identity,
      plan.targetURL.deletingLastPathComponent().standardizedFileURL == scope.workspacesRoot
    else { throw GitCommandRunnerError.cleanupRequired }
    beforeCloneCleanup()
    try requireCleanupDeadline(deadline)
    let quarantineName = ".symphony-failed-clone-\(UUID().uuidString)"
    guard renameatx_np(
      target.parentDescriptor,
      entryName,
      target.parentDescriptor,
      quarantineName,
      UInt32(RENAME_EXCL)
    ) == 0 else { throw GitCommandRunnerError.cleanupRequired }
    guard fstatat(
      target.parentDescriptor,
      quarantineName,
      &targetAtPath,
      AT_SYMLINK_NOFOLLOW
    ) == 0,
      FileIdentity(device: UInt64(targetAtPath.st_dev), inode: UInt64(targetAtPath.st_ino)) == target.identity
    else {
      if renameatx_np(
        target.parentDescriptor,
        quarantineName,
        target.parentDescriptor,
        entryName,
        UInt32(RENAME_EXCL)
      ) != 0 {
        target.recordMove(to: quarantineName)
      }
      throw GitCommandRunnerError.cleanupRequired
    }
    target.recordMove(to: quarantineName)
    let openedForCleanup: Int32
    if target.targetDescriptor >= 0 {
      openedForCleanup = target.targetDescriptor
    } else {
      openedForCleanup = openat(
        target.parentDescriptor,
        quarantineName,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard openedForCleanup >= 0 else { throw GitCommandRunnerError.cleanupRequired }
    }
    defer {
      if target.targetDescriptor < 0 { close(openedForCleanup) }
    }
    try removeDirectoryContents(openedForCleanup, deadline: deadline)
    try requireCleanupDeadline(deadline)
    beforeDestructiveCloneCleanup(target.parentDescriptor, quarantineName)
    var current = stat()
    guard fstatat(
      target.parentDescriptor,
      quarantineName,
      &current,
      AT_SYMLINK_NOFOLLOW
    ) == 0,
      current.st_mode & S_IFMT == S_IFDIR,
      FileIdentity(device: UInt64(current.st_dev), inode: UInt64(current.st_ino)) == target.identity,
      unlinkat(target.parentDescriptor, quarantineName, AT_REMOVEDIR) == 0
    else {
      throw GitCommandRunnerError.cleanupRequired
    }
  }

  private func cleanupPreparedCloneOrRetain(
    _ plan: ValidatedGitOperationPlan,
    target: CloneTargetHandle?,
    scope: AuthorizedGitHubRepositoryScope,
    temporaryDirectory: URL
  ) throws {
    guard let target else { return }
    do {
      try cleanupFailedClone(plan, target: target, scope: scope)
    } catch {
      lock.withLock {
        pendingCloneCleanup = PendingCloneCleanup(
          plan: plan,
          target: target,
          scope: scope,
          temporaryDirectory: temporaryDirectory
        )
      }
      throw GitCommandRunnerError.cleanupRequired
    }
  }

  private func removeDirectoryContents(
    _ descriptor: Int32,
    deadline: ContinuousClock.Instant
  ) throws {
    try requireCleanupDeadline(deadline)
    let enumerationDescriptor = dup(descriptor)
    guard enumerationDescriptor >= 0, let directory = fdopendir(enumerationDescriptor) else {
      if enumerationDescriptor >= 0 { close(enumerationDescriptor) }
      throw GitCommandRunnerError.cleanupRequired
    }
    rewinddir(directory)
    var names: [String] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name != ".", name != ".." { names.append(name) }
    }
    closedir(directory)
    for name in names {
      try requireCleanupDeadline(deadline)
      var information = stat()
      guard fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw GitCommandRunnerError.cleanupRequired
      }
      beforeNestedCloneCleanup(descriptor, name)
      let quarantinedName = ".symphony-cleared-\(UUID().uuidString)"
      guard renameatx_np(
        descriptor,
        name,
        descriptor,
        quarantinedName,
        UInt32(RENAME_EXCL)
      ) == 0 else { throw GitCommandRunnerError.cleanupRequired }
      var captured = stat()
      guard fstatat(descriptor, quarantinedName, &captured, AT_SYMLINK_NOFOLLOW) == 0,
        FileIdentity(device: UInt64(captured.st_dev), inode: UInt64(captured.st_ino))
          == FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
      else {
        _ = renameatx_np(
          descriptor,
          quarantinedName,
          descriptor,
          name,
          UInt32(RENAME_EXCL)
        )
        throw GitCommandRunnerError.cleanupRequired
      }
      if information.st_mode & S_IFMT == S_IFDIR {
        let child = openat(
          descriptor,
          quarantinedName,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else { throw GitCommandRunnerError.cleanupRequired }
        var opened = stat()
        guard fstat(child, &opened) == 0,
          FileIdentity(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino))
            == FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
        else {
          close(child)
          throw GitCommandRunnerError.cleanupRequired
        }
        do {
          try removeDirectoryContents(child, deadline: deadline)
          close(child)
        } catch {
          close(child)
          throw error
        }
        beforeDestructiveCloneCleanup(descriptor, quarantinedName)
        var current = stat()
        guard fstatat(descriptor, quarantinedName, &current, AT_SYMLINK_NOFOLLOW) == 0,
          current.st_mode & S_IFMT == S_IFDIR,
          FileIdentity(device: UInt64(current.st_dev), inode: UInt64(current.st_ino))
            == FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino)),
          unlinkat(descriptor, quarantinedName, AT_REMOVEDIR) == 0
        else {
          throw GitCommandRunnerError.cleanupRequired
        }
      } else if information.st_mode & S_IFMT == S_IFREG {
        let file = openat(descriptor, quarantinedName, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw GitCommandRunnerError.cleanupRequired }
        var opened = stat()
        let matched = fstat(file, &opened) == 0
          && FileIdentity(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino))
            == FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
        beforeDestructiveCloneCleanup(descriptor, quarantinedName)
        var current = stat()
        let stillCurrent = fstatat(
          descriptor,
          quarantinedName,
          &current,
          AT_SYMLINK_NOFOLLOW
        ) == 0
          && current.st_mode & S_IFMT == S_IFREG
          && FileIdentity(device: UInt64(current.st_dev), inode: UInt64(current.st_ino))
            == FileIdentity(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino))
        let unlinked = matched && stillCurrent && unlinkat(descriptor, quarantinedName, 0) == 0
        var detached = stat()
        let cleared = unlinked && fstat(file, &detached) == 0 && detached.st_nlink == 0
          && ftruncate(file, 0) == 0
        close(file)
        guard cleared else { throw GitCommandRunnerError.cleanupRequired }
      } else if information.st_mode & S_IFMT == S_IFLNK {
        beforeDestructiveCloneCleanup(descriptor, quarantinedName)
        var current = stat()
        guard fstatat(descriptor, quarantinedName, &current, AT_SYMLINK_NOFOLLOW) == 0,
          current.st_mode & S_IFMT == S_IFLNK,
          FileIdentity(device: UInt64(current.st_dev), inode: UInt64(current.st_ino))
            == FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino)),
          unlinkat(descriptor, quarantinedName, 0) == 0
        else {
          throw GitCommandRunnerError.cleanupRequired
        }
      } else {
        throw GitCommandRunnerError.cleanupRequired
      }
    }
  }

  private func requireCleanupDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else { throw GitCommandRunnerError.cleanupRequired }
  }
}

private final class GitExecutionAuthority: @unchecked Sendable {
  let descriptor: Int32
  let writeRoot: URL
  let arguments: [String]

  init(descriptor: Int32, writeRoot: URL, arguments: [String]) {
    self.descriptor = descriptor
    self.writeRoot = writeRoot
    self.arguments = arguments
  }

  deinit { Darwin.close(descriptor) }
}

final class GitHubConnectProxy: @unchecked Sendable {
  let port: UInt16
  private let listener: Int32
  private let lock = NSLock()
  private var stopped = false
  private var connections: Set<Int32> = []

  init() throws {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw GitCommandRunnerError.launchFailed }
    var noSignal: Int32 = 1
    guard setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSignal,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
      Darwin.close(descriptor)
      throw GitCommandRunnerError.launchFailed
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, Darwin.listen(descriptor, 4) == 0 else {
      Darwin.close(descriptor)
      throw GitCommandRunnerError.launchFailed
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.getsockname(descriptor, $0, &length)
      }
    }
    guard named == 0 else {
      Darwin.close(descriptor)
      throw GitCommandRunnerError.launchFailed
    }
    listener = descriptor
    port = UInt16(bigEndian: actual.sin_port)
    DispatchQueue.global(qos: .userInitiated).async { [self] in acceptLoop() }
  }

  deinit { stop() }

  func stop() {
    let openConnections = lock.withLock { () -> [Int32] in
      guard !stopped else { return [] }
      stopped = true
      Darwin.shutdown(listener, SHUT_RDWR)
      Darwin.close(listener)
      return Array(connections)
    }
    for descriptor in openConnections { Darwin.shutdown(descriptor, SHUT_RDWR) }
  }

  private func acceptLoop() {
    while !lock.withLock({ stopped }) {
      var address = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let client = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.accept(listener, $0, &length)
        }
      }
      if client < 0 {
        if lock.withLock({ stopped }) { return }
        continue
      }
      lock.withLock { _ = connections.insert(client) }
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        handle(client)
        lock.withLock { _ = connections.remove(client) }
        Darwin.close(client)
      }
    }
  }

  private func handle(_ client: Int32) {
    guard let header = readConnectHeader(from: client),
      let firstLine = String(data: header, encoding: .utf8)?.components(separatedBy: "\r\n").first,
      firstLine == "CONNECT github.com:443 HTTP/1.1" || firstLine == "CONNECT github.com:443 HTTP/1.0",
      let upstream = connectToGitHub()
    else {
      _ = sendAll(Data("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n".utf8), to: client)
      return
    }
    lock.withLock { _ = connections.insert(upstream) }
    defer {
      lock.withLock { _ = connections.remove(upstream) }
      Darwin.shutdown(upstream, SHUT_RDWR)
      Darwin.close(upstream)
    }
    guard sendAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), to: client) else {
      return
    }
    relay(client, upstream)
  }

  private func readConnectHeader(from descriptor: Int32) -> Data? {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var data = Data()
    while data.count < 8_192, ContinuousClock.now < deadline {
      var polled = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let remaining = ContinuousClock.now.duration(to: deadline)
      let milliseconds = max(1, min(250, Int(remaining.components.seconds * 1_000)))
      guard Darwin.poll(&polled, 1, Int32(milliseconds)) >= 0 else { return nil }
      if polled.revents & Int16(POLLIN) == 0 { continue }
      var buffer = [UInt8](repeating: 0, count: 1_024)
      let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
      guard count > 0 else { return nil }
      data.append(contentsOf: buffer.prefix(count))
      if data.range(of: Data("\r\n\r\n".utf8)) != nil { return data }
    }
    return nil
  }

  private func connectToGitHub() -> Int32? {
    var hints = addrinfo(
      ai_flags: 0,
      ai_family: AF_UNSPEC,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo("github.com", "443", &hints, &result) == 0, let first = result else {
      return nil
    }
    defer { freeaddrinfo(first) }
    var current: UnsafeMutablePointer<addrinfo>? = first
    while let candidate = current {
      let descriptor = Darwin.socket(
        candidate.pointee.ai_family,
        candidate.pointee.ai_socktype,
        candidate.pointee.ai_protocol
      )
      if descriptor >= 0 {
        var noSignal: Int32 = 1
        _ = setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          &noSignal,
          socklen_t(MemoryLayout<Int32>.size)
        )
        if Darwin.connect(
          descriptor,
          candidate.pointee.ai_addr,
          candidate.pointee.ai_addrlen
        ) == 0 { return descriptor }
        Darwin.close(descriptor)
      }
      current = candidate.pointee.ai_next
    }
    return nil
  }

  private func relay(_ first: Int32, _ second: Int32) {
    var descriptors = [
      pollfd(fd: first, events: Int16(POLLIN), revents: 0),
      pollfd(fd: second, events: Int16(POLLIN), revents: 0),
    ]
    while !lock.withLock({ stopped }) {
      let count = Darwin.poll(&descriptors, 2, 250)
      if count < 0 { return }
      if count == 0 { continue }
      for index in descriptors.indices where descriptors[index].revents & Int16(POLLIN) != 0 {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let readCount = Darwin.recv(descriptors[index].fd, &buffer, buffer.count, 0)
        guard readCount > 0 else { return }
        let destination = descriptors[index == 0 ? 1 : 0].fd
        guard sendAll(Data(buffer.prefix(readCount)), to: destination) else { return }
      }
      if descriptors.contains(where: {
        $0.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0
      }) { return }
    }
  }

  private func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return true }
      var sent = 0
      while sent < bytes.count {
        let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
        if count <= 0 { return false }
        sent += count
      }
      return true
    }
  }
}

private final class CloneTargetHandle: @unchecked Sendable {
  let parentDescriptor: Int32
  let targetDescriptor: Int32
  let name: String
  let identity: FileIdentity
  private let lock = NSLock()
  private var entryName: String

  init(
    parentDescriptor: Int32,
    targetDescriptor: Int32,
    name: String,
    identity: FileIdentity
  ) {
    self.parentDescriptor = parentDescriptor
    self.targetDescriptor = targetDescriptor
    self.name = name
    self.identity = identity
    entryName = name
  }

  var currentEntryName: String { lock.withLock { entryName } }

  func recordMove(to name: String) {
    lock.withLock { entryName = name }
  }

  deinit {
    if targetDescriptor >= 0 { close(targetDescriptor) }
    close(parentDescriptor)
  }
}

private enum CloneTargetPreparationError: Error {
  case replaced(CloneTargetHandle)
}

struct GitProcessGroupController: Sendable {
  let exists: @Sendable (Int32) -> Bool
  let signal: @Sendable (Int32, Int32) -> Void

  static let system = GitProcessGroupController(
    exists: { processID in
      let result = Darwin.kill(-processID, 0)
      return result == 0 || errno == EPERM
    },
    signal: { processID, signal in
      if Darwin.kill(-processID, signal) != 0 {
        _ = Darwin.kill(processID, signal)
      }
    }
  )
}

private final class GitProcessReference: @unchecked Sendable {
  private let process: Process
  private let ownsProcessGroup: Bool
  private let controller: GitProcessGroupController
  init(
    _ process: Process,
    ownsProcessGroup: Bool,
    controller: GitProcessGroupController
  ) {
    self.process = process
    self.ownsProcessGroup = ownsProcessGroup
    self.controller = controller
  }
  var isRunning: Bool { process.isRunning }
  var groupExists: Bool {
    ownsProcessGroup ? controller.exists(process.processIdentifier) : process.isRunning
  }
  var terminationStatus: Int32 { process.terminationStatus }
  func terminateGroup(_ signal: Int32) {
    controller.signal(process.processIdentifier, signal)
  }
}

enum TrustedSystemGitExecutable {
  static func locate() -> URL? {
    let candidates = ["/Library/Developer/CommandLineTools/usr/bin/git"]
    return candidates.lazy.compactMap { validatedExecutable(at: $0) }.first
  }

  private static func validatedExecutable(at path: String) -> URL? {
    let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    var information = stat()
    guard lstat(candidate.path, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG,
      information.st_uid == 0,
      information.st_mode & (S_IWGRP | S_IWOTH) == 0,
      Darwin.access(candidate.path, X_OK) == 0
    else { return nil }
    return candidate
  }
}

private final class GitOutputCollector: @unchecked Sendable {
  private let handle: FileHandle
  private let maximumBytes: Int
  private let lock = NSLock()
  private var data = Data()
  private var exceeded = false
  private var didFinish = false

  init(handle: FileHandle, maximumBytes: Int) {
    self.handle = handle
    self.maximumBytes = maximumBytes
  }

  var exceededLimit: Bool { lock.withLock { exceeded } }
  var prefix: Data { lock.withLock { data } }
  var finished: Bool { lock.withLock { didFinish } }

  func readToEnd() {
    defer { lock.withLock { didFinish = true } }
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
  case timedOutWithOutput(String), outputTooLarge(String), failed(Int32, String)

  var failure: GitHubCapabilityFailure {
    switch self {
    case .launchFailed:
      GitHubCapabilityFailure(category: .gitFailed, message: "Git could not start safely.")
    case .timedOut:
      GitHubCapabilityFailure(category: .timedOut, message: "Git did not finish within five minutes.")
    case .timedOutWithOutput(let output):
      GitHubCapabilityFailure(
        category: .timedOut,
        message: "Git did not finish within five minutes. \(output)"
      )
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

struct GitCredentialWireRequest: Codable {
  let action: String
  let input: Data

  init(action: String, input: Data) {
    self.action = action
    self.input = input
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: AnyWireCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.stringValue)) else {
      throw GitCommandRunnerError.authenticationRejected
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      action: try container.decode(String.self, forKey: .action),
      input: try container.decode(Data.self, forKey: .input)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable { case action, input }
}

struct GitCredentialWireResponse: Codable {
  let succeeded: Bool
  let output: Data

  init(succeeded: Bool, output: Data) {
    self.succeeded = succeeded
    self.output = output
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: AnyWireCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.stringValue)) else {
      throw GitCommandRunnerError.authenticationRejected
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      succeeded: try container.decode(Bool.self, forKey: .succeeded),
      output: try container.decode(Data.self, forKey: .output)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable { case succeeded, output }
}

private struct AnyWireCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?
  init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
  init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

final class PrivateGitCredentialServer: @unchecked Sendable {
  private let descriptor: Int32
  let clientHandle: FileHandle
  private let scope: AuthorizedGitHubRepositoryScope
  private let credential: OperationCredential
  private let stateLock = NSLock()
  private var stopped = false
  private var rejected = false

  init(scope: AuthorizedGitHubRepositoryScope, credential: OperationCredential) throws {
    self.scope = scope
    self.credential = credential
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw GitCommandRunnerError.launchFailed
    }
    var enabled: Int32 = 1
    guard setsockopt(
      descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)
    ) == 0,
      setsockopt(
        descriptors[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      Darwin.close(descriptors[0])
      Darwin.close(descriptors[1])
      throw GitCommandRunnerError.launchFailed
    }
    descriptor = descriptors[0]
    clientHandle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
  }

  var authenticationWasRejected: Bool { stateLock.withLock { rejected } }

  var helperEnvironment: [String: String] {
    ["SYMPHONY_GIT_HELPER_FD": String(clientHandle.fileDescriptor)]
  }

  func serve() {
    while !stateLock.withLock({ stopped }) {
      do {
        let data = try SocketLine.read(
          descriptor,
          maximumBytes: 32_768,
          timeoutMilliseconds: 5_000,
          isCancelled: { self.stateLock.withLock { self.stopped } }
        )
        let request = try JSONDecoder().decode(GitCredentialWireRequest.self, from: data)
        let response = try conversation(action: request.action, input: request.input)
        try SocketLine.write(JSONEncoder().encode(response), to: descriptor)
      } catch GitCommandRunnerError.timedOut {
        continue
      } catch {
        if stateLock.withLock({ stopped }) { break }
        let response = GitCredentialWireResponse(succeeded: false, output: Data())
        try? SocketLine.write(JSONEncoder().encode(response), to: descriptor)
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

  func closeClientCopy() {
    try? clientHandle.close()
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
      let descriptorText = environment["SYMPHONY_GIT_HELPER_FD"],
      let descriptor = Int32(descriptorText),
      descriptor >= 3,
      input.count <= CredentialBrokerProtocolLimits.maximumGitCredentialInputBytes
    else { return (1, Data()) }
    do {
      let request = GitCredentialWireRequest(action: action, input: input)
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
  static func read(
    _ descriptor: Int32,
    maximumBytes: Int,
    timeoutMilliseconds: Int32,
    isCancelled: () -> Bool = { false }
  ) throws -> Data {
    let deadline = ContinuousClock.now.advanced(
      by: .milliseconds(Int64(timeoutMilliseconds))
    )
    var data = Data()
    while data.count <= maximumBytes, ContinuousClock.now < deadline {
      guard !isCancelled() else { throw GitCommandRunnerError.authenticationRejected }
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let remaining = ContinuousClock.now.duration(to: deadline)
      let components = remaining.components
      let remainingMilliseconds = max(
        1,
        min(
          Int64(Int32.max),
          components.seconds * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
        )
      )
      let result = Darwin.poll(&pollDescriptor, 1, Int32(min(50, remainingMilliseconds)))
      guard result >= 0 else { throw GitCommandRunnerError.authenticationRejected }
      if result == 0 { continue }
      var byte: UInt8 = 0
      guard Darwin.recv(descriptor, &byte, 1, 0) == 1 else {
        throw GitCommandRunnerError.authenticationRejected
      }
      if byte == 0x0A { return data }
      data.append(byte)
    }
    guard data.count > maximumBytes else { throw GitCommandRunnerError.timedOut }
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
