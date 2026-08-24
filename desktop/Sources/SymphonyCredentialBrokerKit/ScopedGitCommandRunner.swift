import Darwin
import Foundation
import Network
import Security
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
    let watchdog: GitLifetimeWatchdog?
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
    let isolated: (environment: [String: String], temporaryDirectory: URL, descriptor: Int32)
    do {
      isolated = try isolatedEnvironment()
    } catch {
      throw error
    }
    defer { Darwin.close(isolated.descriptor) }
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
      throw clonePreparationFailure(error, hasCloneTarget: cloneTarget != nil)
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
      throw clonePreparationFailure(error, hasCloneTarget: cloneTarget != nil)
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
      throw clonePreparationFailure(error, hasCloneTarget: cloneTarget != nil)
    }
    let proxy: GitHubConnectProxy?
    do {
      proxy = wrapsGitInBrokerExecutable
        ? try GitHubConnectProxy(scope: scope, credential: credential)
        : nil
    } catch {
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
    let server: PrivateGitCredentialServer
    do {
      server = try PrivateGitCredentialServer(
        scope: scope,
        credential: proxy?.localCredential ?? credential,
        credentialURL: proxy?.repositoryURL ?? scope.repositoryURL
      )
    } catch {
      proxy?.stop()
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
    let output = Pipe()
    let arguments = gitArguments(
      wrapsGitInBrokerExecutable
        ? authority.arguments
        : unsandboxedOperationArguments(plan, cloneTarget: cloneTarget),
      repositoryURL: scope.repositoryURL,
      brokerRepositoryURL: proxy?.repositoryURL
    )
    let processEnvironment = isolated.environment
    let processReference: GitProcessReference
    var launchedReference: GitProcessReference?
    var watchdog: GitLifetimeWatchdog?
    do {
      if wrapsGitInBrokerExecutable {
        processReference = try spawnSandboxedGit(
          authority: authority,
          temporaryDirectory: isolated.temporaryDirectory,
          temporaryDescriptor: isolated.descriptor,
          proxyPort: proxy!.port,
          gitArguments: arguments,
          environment: processEnvironment,
          credentialDescriptor: server.clientHandle.fileDescriptor,
          outputDescriptor: output.fileHandleForWriting.fileDescriptor
        )
      } else {
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.environment = processEnvironment
        process.standardInput = server.clientHandle
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let ownsProcessGroup = Darwin.setpgid(
          process.processIdentifier,
          process.processIdentifier
        ) == 0 || Darwin.getpgid(process.processIdentifier) == process.processIdentifier
        processReference = GitProcessReference(
          process,
          ownsProcessGroup: ownsProcessGroup,
          controller: processGroupController
        )
      }
      launchedReference = processReference
      afterProcessGroupEstablished(processReference.processIdentifier)
      if wrapsGitInBrokerExecutable {
        watchdog = try GitLifetimeWatchdog(processGroup: processReference.processIdentifier)
      }
      output.fileHandleForWriting.closeFile()
      server.closeClientCopy()
    } catch {
      launchedReference?.terminateGroup(SIGKILL)
      output.fileHandleForWriting.closeFile()
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
    let ownedRuntime = RetainedRuntime(
      process: processReference,
      server: server,
      proxy: proxy,
      credential: credential,
      temporaryDirectory: isolated.temporaryDirectory,
      plan: plan,
      cloneTarget: cloneTarget,
      authority: authority,
      scope: scope,
      watchdog: watchdog
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
    watchdog?.stop()
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
      runtime.watchdog?.stop()
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
      retained.watchdog?.stop()
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
    brokerRepositoryURL: URL?
  ) -> [String] {
    let helper = Self.inheritedCredentialHelper
    let effectiveRepositoryURL = brokerRepositoryURL ?? repositoryURL
    let repositoryHTTPKey = "http.\(effectiveRepositoryURL.absoluteString)"
    let effectiveArguments = operationArguments.map {
      $0 == repositoryURL.absoluteString ? effectiveRepositoryURL.absoluteString : $0
    }
    return [
      "-c", "credential.helper=",
      "-c", "credential.helper=!\(helper)",
      "-c", "credential.useHttpPath=true",
      "-c", "http.followRedirects=false",
      "-c", "http.proxy=",
      "-c", "http.sslVerify=true",
      "-c", "http.extraHeader=",
      "-c", "http.cookieFile=",
      "-c", "http.saveCookies=false",
      "-c", "\(repositoryHTTPKey).proxy=",
      "-c", "\(repositoryHTTPKey).sslVerify=true",
      "-c", "\(repositoryHTTPKey).extraHeader=",
      "-c", "\(repositoryHTTPKey).cookieFile=",
      "-c", "protocol.allow=never",
      "-c", "protocol.https.allow=always",
      "-c", "core.hooksPath=/dev/null",
    ] + effectiveArguments
  }

  /// The helper is interpreted by Git's trusted `/bin/sh`; it never reopens the
  /// application bundle or another user-writable executable path. Descriptor 3
  /// is inherited only by the sandboxed Git process tree.
  static let inheritedCredentialHelper = #"f() { request=$(/usr/bin/base64 | /usr/bin/tr -d '\n') || exit 1; printf '%s %s\n' "$1" "$request" >&3 || exit 1; IFS=' ' read -r status response <&3 || exit 1; [ "$status" = OK ] || exit 1; [ "$response" = - ] || printf '%s' "$response" | /usr/bin/base64 -D; }; f"#

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
    temporaryDescriptor: Int32,
    proxyPort: UInt16
  ) throws -> [String] {
    let writeRoot = try authority.descriptorBoundPath()
    let temporaryRoot = try Self.descriptorBoundPath(temporaryDescriptor)
    return [
      "-D", "WRITE_ROOT=\(writeRoot)",
      "-D", "TEMP_ROOT=\(temporaryRoot)",
      "-D", "GIT_EXECUTABLE=\(Self.canonicalSandboxPath(gitExecutableURL.path))",
      "-D", "GIT_CORE=\(Self.canonicalSandboxPath(gitExecutableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("libexec/git-core").path))",
      "-p", Self.sandboxProfile(proxyPort: proxyPort),
    ]
  }

  static func canonicalSandboxPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard realpath(path, &buffer) != nil else { return path }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func descriptorBoundPath(_ descriptor: Int32) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
      throw GitRepositoryTrustError.filesystemChanged
    }
    let path = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    var opened = stat()
    var atPath = stat()
    guard fstat(descriptor, &opened) == 0,
      lstat(path, &atPath) == 0,
      opened.st_dev == atPath.st_dev,
      opened.st_ino == atPath.st_ino
    else { throw GitRepositoryTrustError.filesystemChanged }
    return path
  }

  static func sandboxProfile(proxyPort: UInt16) -> String {
    """
    (version 1)
    (deny default)
    (allow process-fork)
    (allow process-exec
      (literal (param "GIT_EXECUTABLE"))
      (subpath (param "GIT_CORE"))
      (literal "/bin/sh")
      (literal "/bin/bash")
      (literal "/bin/sleep")
      (literal "/usr/bin/touch")
      (literal "/usr/bin/base64")
      (literal "/usr/bin/tr"))
    (allow signal (target same-sandbox))
    (allow process-info* (target same-sandbox))
    (allow file-read*)
    (allow file-ioctl)
    (allow file-write-data (require-not (vnode-type REGULAR-FILE)))
    (allow file-write*
      (literal (param "WRITE_ROOT"))
      (subpath (param "WRITE_ROOT"))
      (literal (param "TEMP_ROOT"))
      (subpath (param "TEMP_ROOT"))
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

  private func spawnSandboxedGit(
    authority: GitExecutionAuthority,
    temporaryDirectory: URL,
    temporaryDescriptor: Int32,
    proxyPort: UInt16,
    gitArguments: [String],
    environment: [String: String],
    credentialDescriptor: Int32,
    outputDescriptor: Int32
  ) throws -> GitProcessReference {
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      throw GitCommandRunnerError.launchFailed
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_adddup2(&actions, credentialDescriptor, 3) == 0,
      posix_spawn_file_actions_adddup2(&actions, outputDescriptor, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, outputDescriptor, STDERR_FILENO) == 0,
      posix_spawn_file_actions_addfchdir_np(&actions, authority.descriptor) == 0
    else { throw GitCommandRunnerError.launchFailed }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw GitCommandRunnerError.launchFailed
    }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else { throw GitCommandRunnerError.launchFailed }

    let arguments = [sandboxExecutableURL.path]
      + (try sandboxArguments(
        authority: authority,
        temporaryDirectory: temporaryDirectory,
        temporaryDescriptor: temporaryDescriptor,
        proxyPort: proxyPort
      ))
      + [gitExecutableURL.path] + gitArguments
    var argumentPointers = arguments.map { strdup($0) }
    var environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") }
    guard argumentPointers.allSatisfy({ $0 != nil }), environmentPointers.allSatisfy({ $0 != nil }) else {
      argumentPointers.compactMap { $0 }.forEach { free(UnsafeMutableRawPointer($0)) }
      environmentPointers.compactMap { $0 }.forEach { free(UnsafeMutableRawPointer($0)) }
      throw GitCommandRunnerError.launchFailed
    }
    defer {
      argumentPointers.compactMap { $0 }.forEach { free(UnsafeMutableRawPointer($0)) }
      environmentPointers.compactMap { $0 }.forEach { free(UnsafeMutableRawPointer($0)) }
    }
    argumentPointers.append(nil)
    environmentPointers.append(nil)
    var processID: pid_t = 0
    let result = sandboxExecutableURL.path.withCString { executable in
      posix_spawn(
        &processID,
        executable,
        &actions,
        &attributes,
        &argumentPointers,
        &environmentPointers
      )
    }
    guard result == 0, processID > 1 else { throw GitCommandRunnerError.launchFailed }
    return GitProcessReference(
      processID: processID,
      ownsProcessGroup: true,
      controller: processGroupController
    )
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

  private func isolatedEnvironment() throws -> (
    environment: [String: String], temporaryDirectory: URL, descriptor: Int32
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-git-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    guard chmod(directory.path, S_IRWXU) == 0 else {
      try? FileManager.default.removeItem(at: directory)
      throw GitCommandRunnerError.launchFailed
    }
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
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
    ], directory, descriptor)
  }

  private func removeIsolatedDirectory(_ directory: URL) {
    // Never recursively delete a pathname that another same-UID process can
    // replace. A clean Git operation leaves this directory empty; non-empty
    // diagnostic residue is preserved for explicit recovery.
    _ = Darwin.rmdir(directory.path)
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

  private func clonePreparationFailure(_ error: Error, hasCloneTarget: Bool) -> Error {
    guard hasCloneTarget, error is GitRepositoryTrustError else { return error }
    return GitCommandRunnerError.cleanupRequired
  }

  private func requireNoOrphanedCloneResidue(in root: URL) throws {
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0, let directory = fdopendir(descriptor) else {
      if descriptor >= 0 { close(descriptor) }
      throw GitCommandRunnerError.cleanupRequired
    }
    defer { closedir(directory) }
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
    var count = 0
    while let entry = readdir(directory) {
      count += 1
      guard count <= 100_000, ContinuousClock.now < deadline else {
        throw GitCommandRunnerError.cleanupRequired
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      guard !name.hasPrefix(".symphony-clone-"),
        !name.hasPrefix(".symphony-failed-clone-")
      else { throw GitCommandRunnerError.cleanupRequired }
    }
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
    var created = stat()
    guard fstatat(parentDescriptor, name, &created, AT_SYMLINK_NOFOLLOW) == 0,
      created.st_mode & S_IFMT == S_IFDIR
    else {
      close(parentDescriptor)
      throw GitCommandRunnerError.cleanupRequired
    }
    let createdIdentity = FileIdentity(
      device: UInt64(created.st_dev),
      inode: UInt64(created.st_ino)
    )
    beforeCloneTargetOpen(parentDescriptor, name)
    let targetDescriptor = openat(
      parentDescriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    var opened = stat()
    guard targetDescriptor >= 0, fstat(targetDescriptor, &opened) == 0,
      opened.st_mode & S_IFMT == S_IFDIR,
      FileIdentity(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino)) == createdIdentity
    else {
      if targetDescriptor >= 0 { close(targetDescriptor) }
      throw CloneTargetPreparationError.replaced(
        CloneTargetHandle(
          parentDescriptor: parentDescriptor,
          targetDescriptor: -1,
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
    guard case .clone = plan.request, target != nil else { return }
    _ = scope
    _ = suppliedDeadline
    // A same-UID peer can replace any pathname between identity validation and
    // unlinkat(2). Preserve failed broker-created staging instead of risking
    // deletion or truncation of a replacement. Admission detects the reserved
    // staging prefix and returns an actionable cleanup-required failure.
    beforeCloneCleanup()
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

  func descriptorBoundPath() throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
      throw GitRepositoryTrustError.filesystemChanged
    }
    let path = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    var opened = stat()
    var atPath = stat()
    guard fstat(descriptor, &opened) == 0,
      lstat(path, &atPath) == 0,
      opened.st_dev == atPath.st_dev,
      opened.st_ino == atPath.st_ino
    else { throw GitRepositoryTrustError.filesystemChanged }
    return path
  }

  deinit { Darwin.close(descriptor) }
}

private final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }
  var value: Value { lock.withLock { storage } }
  func set(_ value: Value) { lock.withLock { storage = value } }
}

final class GitHubConnectProxy: @unchecked Sendable {
  let port: UInt16
  let repositoryURL: URL
  let localCredential: OperationCredential
  private let listener: Int32
  private let scope: AuthorizedGitHubRepositoryScope
  private let credential: OperationCredential
  private let lock = NSLock()
  private let workers = DispatchGroup()
  private var stopped = false
  private var clients: Set<Int32> = []
  private var upstreams: [ObjectIdentifier: NWConnection] = [:]

  init(scope: AuthorizedGitHubRepositoryScope, credential: OperationCredential) throws {
    self.scope = scope
    self.credential = credential
    var grantBytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, grantBytes.count, &grantBytes) == errSecSuccess else {
      throw GitCommandRunnerError.launchFailed
    }
    let grantSource = SecureSecretBuffer(
      copying: Data(Data(grantBytes).base64EncodedString().utf8)
    )
    localCredential = OperationCredential(copying: grantSource)
    grantSource.clear()
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
    repositoryURL = URL(
      string: "http://127.0.0.1:\(port)/\(scope.owner)/\(scope.repository).git"
    )!
    workers.enter()
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      acceptLoop()
      workers.leave()
    }
  }

  deinit { stop() }

  func stop() {
    let openConnections = lock.withLock { () -> ([Int32], [NWConnection]) in
      guard !stopped else { return ([], []) }
      stopped = true
      Darwin.shutdown(listener, SHUT_RDWR)
      Darwin.close(listener)
      return (Array(clients), Array(upstreams.values))
    }
    for descriptor in openConnections.0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
    for connection in openConnections.1 { connection.cancel() }
    _ = workers.wait(timeout: .now() + .seconds(1))
    localCredential.clear()
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
      lock.withLock { _ = clients.insert(client) }
      workers.enter()
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        handle(client)
        lock.withLock { _ = clients.remove(client) }
        Darwin.close(client)
        workers.leave()
      }
    }
  }

  private func handle(_ client: Int32) {
    guard let request = readRequestHeader(from: client),
      let rewritten = rewriteRequest(request.header),
      let upstream = connectToGitHub()
    else {
      _ = sendAll(Data("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n".utf8), to: client)
      return
    }
    let identifier = ObjectIdentifier(upstream)
    lock.withLock { upstreams[identifier] = upstream }
    defer {
      _ = lock.withLock { upstreams.removeValue(forKey: identifier) }
      upstream.cancel()
    }
    var initial = rewritten
    initial.append(request.remainder)
    guard send(initial, to: upstream) else { return }
    relayRequestBody(
      from: client,
      to: upstream,
      alreadyReceived: request.remainder,
      framing: requestBodyFraming(request.header)
    )
    relayResponse(from: upstream, to: client)
  }

  private func readRequestHeader(from descriptor: Int32) -> (header: Data, remainder: Data)? {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var data = Data()
    let delimiter = Data("\r\n\r\n".utf8)
    while data.count < 32_768, ContinuousClock.now < deadline {
      var polled = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let remaining = ContinuousClock.now.duration(to: deadline)
      let milliseconds = max(1, min(250, Int(remaining.components.seconds * 1_000)))
      guard Darwin.poll(&polled, 1, Int32(milliseconds)) >= 0 else { return nil }
      if polled.revents & Int16(POLLIN) == 0 { continue }
      var buffer = [UInt8](repeating: 0, count: 1_024)
      let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
      guard count > 0 else { return nil }
      data.append(contentsOf: buffer.prefix(count))
      if let range = data.range(of: delimiter) {
        return (Data(data[..<range.upperBound]), Data(data[range.upperBound...]))
      }
    }
    return nil
  }

  private func rewriteRequest(_ header: Data) -> Data? {
    guard let text = String(data: header, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestFields = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard requestFields.count == 3,
      ["GET", "POST", "HEAD"].contains(String(requestFields[0])),
      requestFields[2] == "HTTP/1.1",
      requestPathIsAuthorized(String(requestFields[1]))
    else { return nil }
    var suppliedAuthorization: String?
    var retained: [String] = []
    for line in lines.dropFirst() where !line.isEmpty {
      guard let separator = line.firstIndex(of: ":") else { return nil }
      let name = line[..<separator].lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      if name == "authorization" {
        guard suppliedAuthorization == nil else { return nil }
        suppliedAuthorization = value
      } else if !["host", "connection", "proxy-connection", "proxy-authorization"].contains(name) {
        retained.append(line)
      }
    }
    guard localCredential.buffer.withTemporaryData({ grant in
      let expected = "Basic " + Data("x-access-token:".utf8 + grant).base64EncodedString()
      return suppliedAuthorization == expected
    }) else { return nil }
    let upstreamAuthorization = credential.buffer.withTemporaryData { token in
      "Authorization: Basic " + Data("x-access-token:".utf8 + token).base64EncodedString()
    }
    return Data(
      ([requestLine, "Host: github.com", upstreamAuthorization, "Connection: close"] + retained)
        .joined(separator: "\r\n").appending("\r\n\r\n").utf8
    )
  }

  private func requestPathIsAuthorized(_ value: String) -> Bool {
    guard value.first == "/", !value.contains("%"), !value.contains("..") else { return false }
    let path = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let repositoryPath = "/\(scope.owner)/\(scope.repository).git"
    return path == repositoryPath || path.hasPrefix(repositoryPath + "/")
  }

  private enum RequestBodyFraming { case none, length(Int), chunked }

  private func requestBodyFraming(_ header: Data) -> RequestBodyFraming {
    guard let text = String(data: header, encoding: .utf8) else { return .none }
    for line in text.components(separatedBy: "\r\n").dropFirst() {
      let lower = line.lowercased()
      if lower == "transfer-encoding: chunked" { return .chunked }
      if lower.hasPrefix("content-length:"),
        let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
        length >= 0
      { return .length(length) }
    }
    return .none
  }

  private func connectToGitHub() -> NWConnection? {
    let connection = NWConnection(host: "github.com", port: 443, using: .tls)
    let semaphore = DispatchSemaphore(value: 0)
    let ready = LockedValue(false)
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        ready.set(true)
        semaphore.signal()
      case .failed, .cancelled:
        semaphore.signal()
      default:
        break
      }
    }
    connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    guard semaphore.wait(timeout: .now() + .seconds(5)) == .success,
      ready.value
    else {
      connection.cancel()
      return nil
    }
    return connection
  }

  private func relayRequestBody(
    from client: Int32,
    to upstream: NWConnection,
    alreadyReceived: Data,
    framing: RequestBodyFraming
  ) {
    var remaining: Int?
    var chunkTail = Data(alreadyReceived.suffix(16))
    switch framing {
    case .none:
      upstream.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in })
      return
    case .length(let length):
      remaining = max(0, length - alreadyReceived.count)
    case .chunked:
      if chunkTail.range(of: Data("\r\n0\r\n\r\n".utf8)) != nil { remaining = 0 }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while remaining != 0, ContinuousClock.now < deadline, !lock.withLock({ stopped }) {
      var polled = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
      guard Darwin.poll(&polled, 1, 250) >= 0 else { break }
      if polled.revents & Int16(POLLIN) == 0 { continue }
      var buffer = [UInt8](repeating: 0, count: 16_384)
      let requested = min(buffer.count, remaining ?? buffer.count)
      let count = Darwin.recv(client, &buffer, requested, 0)
      guard count > 0 else { break }
      let data = Data(buffer.prefix(count))
      guard send(data, to: upstream) else { break }
      if let value = remaining { remaining = max(0, value - count) }
      if case .chunked = framing {
        chunkTail.append(data)
        chunkTail = Data(chunkTail.suffix(32))
        if chunkTail.range(of: Data("\r\n0\r\n\r\n".utf8)) != nil { remaining = 0 }
      }
    }
    upstream.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in })
  }

  private func relayResponse(from upstream: NWConnection, to client: Int32) {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline, !lock.withLock({ stopped }) {
      let semaphore = DispatchSemaphore(value: 0)
      let result = LockedValue<(Data?, Bool, Bool)>((nil, false, false))
      upstream.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
        result.set((data, isComplete, error != nil))
        semaphore.signal()
      }
      guard semaphore.wait(timeout: .now() + .milliseconds(500)) == .success else { continue }
      let (received, complete, failed) = result.value
      if let received, !sendAll(received, to: client) { return }
      if complete || failed { return }
    }
  }

  private func send(_ data: Data, to connection: NWConnection) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    let succeeded = LockedValue(false)
    connection.send(content: data, completion: .contentProcessed { error in
      succeeded.set(error == nil)
      semaphore.signal()
    })
    return semaphore.wait(timeout: .now() + .seconds(5)) == .success && succeeded.value
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

private final class GitLifetimeWatchdog: @unchecked Sendable {
  private let process: Process
  private let writer: FileHandle
  private let lock = NSLock()
  private var stopped = false

  init(processGroup: Int32) throws {
    let lifetime = Pipe()
    process = Process()
    writer = lifetime.fileHandleForWriting
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "if ! IFS= read -r _; then /bin/kill -KILL -- -\"$1\" 2>/dev/null; fi",
      "symphony-git-watchdog",
      String(processGroup),
    ]
    process.standardInput = lifetime.fileHandleForReading
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    lifetime.fileHandleForReading.closeFile()
  }

  deinit { stop() }

  func stop() {
    let shouldStop = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      stopped = true
      return true
    }
    guard shouldStop else { return }
    try? writer.close()
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
    while process.isRunning, ContinuousClock.now < deadline { usleep(1_000) }
    if process.isRunning { process.terminate() }
  }
}

private final class GitProcessReference: @unchecked Sendable {
  private let process: Process?
  let processIdentifier: Int32
  private let ownsProcessGroup: Bool
  private let controller: GitProcessGroupController
  private let stateLock = NSLock()
  private var waitedStatus: Int32?
  init(
    _ process: Process,
    ownsProcessGroup: Bool,
    controller: GitProcessGroupController
  ) {
    self.process = process
    processIdentifier = process.processIdentifier
    self.ownsProcessGroup = ownsProcessGroup
    self.controller = controller
  }

  init(
    processID: Int32,
    ownsProcessGroup: Bool,
    controller: GitProcessGroupController
  ) {
    process = nil
    processIdentifier = processID
    self.ownsProcessGroup = ownsProcessGroup
    self.controller = controller
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      var status: Int32 = 0
      while Darwin.waitpid(processID, &status, 0) < 0, errno == EINTR {}
      stateLock.withLock { waitedStatus = status }
    }
  }

  var isRunning: Bool {
    if let process { return process.isRunning }
    return stateLock.withLock { waitedStatus == nil }
  }
  var groupExists: Bool {
    ownsProcessGroup ? controller.exists(processIdentifier) : isRunning
  }
  var terminationStatus: Int32 {
    if let process { return process.terminationStatus }
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
    while stateLock.withLock({ waitedStatus == nil }), ContinuousClock.now < deadline {
      usleep(1_000)
    }
    guard let status = stateLock.withLock({ waitedStatus }) else { return 1 }
    let terminationSignal = status & 0x7f
    if terminationSignal == 0 { return (status >> 8) & 0xff }
    if terminationSignal != 0x7f { return 128 + terminationSignal }
    return 1
  }
  func terminateGroup(_ signal: Int32) {
    controller.signal(processIdentifier, signal)
  }
}

enum TrustedSystemGitExecutable {
  static func locate() -> URL? {
    let candidates = [
      "/Library/Developer/CommandLineTools/usr/bin/git",
      "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ]
    return candidates.lazy.compactMap { validatedExecutable(at: $0) }.first
  }

  static func validatedExecutable(at path: String) -> URL? {
    let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    var information = stat()
    guard lstat(candidate.path, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG,
      information.st_uid == 0,
      information.st_mode & (S_IWGRP | S_IWOTH) == 0,
      Darwin.access(candidate.path, X_OK) == 0
    else { return nil }
    var ancestor = candidate.deletingLastPathComponent()
    while ancestor.path != "/" {
      guard lstat(ancestor.path, &information) == 0,
        information.st_mode & S_IFMT == S_IFDIR,
        information.st_uid == 0,
        information.st_mode & (S_IWGRP | S_IWOTH) == 0
      else { return nil }
      ancestor.deleteLastPathComponent()
    }
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
  private let credentialURL: URL
  private let stateLock = NSLock()
  private var stopped = false
  private var rejected = false

  init(
    scope: AuthorizedGitHubRepositoryScope,
    credential: OperationCredential,
    credentialURL: URL? = nil
  ) throws {
    self.scope = scope
    self.credential = credential
    self.credentialURL = credentialURL ?? scope.repositoryURL
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
        if data.first == UInt8(ascii: "{") {
          let request = try JSONDecoder().decode(GitCredentialWireRequest.self, from: data)
          let response = try conversation(action: request.action, input: request.input)
          try SocketLine.write(JSONEncoder().encode(response), to: descriptor)
        } else {
          let fields = data.split(separator: UInt8(ascii: " "), maxSplits: 1)
          guard fields.count == 2,
            let action = String(data: fields[0], encoding: .utf8),
            let input = Data(base64Encoded: Data(fields[1]))
          else { throw GitCommandRunnerError.authenticationRejected }
          let response = try conversation(action: action, input: input)
          let encoded = response.output.isEmpty ? "-" : response.output.base64EncodedString()
          try SocketLine.write(Data("\(response.succeeded ? "OK" : "ERR") \(encoded)".utf8), to: descriptor)
        }
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
    guard action == "get", let values = GitCredentialInput(input),
      values.matches(scope, credentialURL: credentialURL)
    else {
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

  func matches(_ scope: AuthorizedGitHubRepositoryScope, credentialURL: URL) -> Bool {
    guard values["protocol"]?.lowercased() == credentialURL.scheme?.lowercased(),
      values["host"]?.lowercased() == credentialURL.authorityForGitCredential.lowercased(),
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

private extension URL {
  var authorityForGitCredential: String {
    guard let host else { return "" }
    if let port { return "\(host):\(port)" }
    return host
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
