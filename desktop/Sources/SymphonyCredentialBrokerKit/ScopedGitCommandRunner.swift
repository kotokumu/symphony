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
    let plan: ValidatedGitOperationPlan
    let cloneTarget: CloneTargetHandle?
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
  private let operationTimeout: TimeInterval
  private let stopTimeout: TimeInterval
  private let wrapsGitInBrokerExecutable: Bool
  private let beforeLaunch: @Sendable () async -> Void
  private let beforeCloneCleanup: @Sendable () -> Void
  private let beforeCloneTargetOpen: @Sendable (Int32, String) -> Void
  private let afterEffectiveConfigurationPrepared: @Sendable (URL?) -> Void
  private let beforeNestedCloneCleanup: @Sendable (Int32, String) -> Void
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
    gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
    brokerExecutableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
    operationTimeout: TimeInterval = 300,
    stopTimeout: TimeInterval = 0.75,
    wrapsGitInBrokerExecutable: Bool = true,
    beforeLaunch: @escaping @Sendable () async -> Void = {},
    beforeCloneCleanup: @escaping @Sendable () -> Void = {},
    beforeCloneTargetOpen: @escaping @Sendable (Int32, String) -> Void = { _, _ in },
    afterEffectiveConfigurationPrepared: @escaping @Sendable (URL?) -> Void = { _ in },
    beforeNestedCloneCleanup: @escaping @Sendable (Int32, String) -> Void = { _, _ in },
    afterProcessGroupEstablished: @escaping @Sendable (Int32) -> Void = { _ in },
    processGroupController: GitProcessGroupController = .system
  ) {
    self.policy = policy
    self.gitExecutableURL = gitExecutableURL
    self.brokerExecutableURL = brokerExecutableURL
    self.operationTimeout = operationTimeout
    self.stopTimeout = stopTimeout
    self.wrapsGitInBrokerExecutable = wrapsGitInBrokerExecutable
    self.beforeLaunch = beforeLaunch
    self.beforeCloneCleanup = beforeCloneCleanup
    self.beforeCloneTargetOpen = beforeCloneTargetOpen
    self.afterEffectiveConfigurationPrepared = afterEffectiveConfigurationPrepared
    self.beforeNestedCloneCleanup = beforeNestedCloneCleanup
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
    let effectiveGitDirectory: URL?
    do {
      effectiveGitDirectory = try prepareEffectiveGitDirectory(plan, in: isolated.temporaryDirectory)
      afterEffectiveConfigurationPrepared(effectiveGitDirectory)
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
    let process = Process()
    let output = Pipe()
    let arguments = gitArguments(
      operationArguments(plan, cloneTarget: cloneTarget, effectiveGitDirectory: effectiveGitDirectory),
      repositoryURL: scope.repositoryURL
    )
    process.executableURL = wrapsGitInBrokerExecutable ? brokerExecutableURL : gitExecutableURL
    process.arguments = wrapsGitInBrokerExecutable
      ? ["git-runner", gitExecutableURL.path] + arguments
      : arguments
    process.environment = isolated.environment
    process.standardInput = server.clientHandle
    process.standardOutput = output
    process.standardError = output
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
      credential: credential,
      temporaryDirectory: isolated.temporaryDirectory,
      plan: plan,
      cloneTarget: cloneTarget,
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
    server.stop()
    _ = await serverTask.value
    output.fileHandleForReading.closeFile()
    _ = await reader.value
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
    if timedOut || Task.isCancelled { throw GitCommandRunnerError.timedOut }
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
    let runtime = lock.withLock { () -> RetainedRuntime? in
      stopRequested = true
      return retained ?? active
    }
    if let runtime {
      try await stop(runtime.process)
      runtime.server.stop()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while lock.withLock({ operationInProgress }), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    guard !lock.withLock({ operationInProgress }) else {
      throw GitCommandRunnerError.cleanupRequired
    }
    if let pending = lock.withLock({ pendingCloneCleanup }) {
      try cleanupFailedClone(pending.plan, target: pending.target, scope: pending.scope)
      removeIsolatedDirectory(pending.temporaryDirectory)
      lock.withLock { pendingCloneCleanup = nil }
    }
    if let retained = lock.withLock({ self.retained }) {
      guard !retained.process.groupExists else { throw GitCommandRunnerError.cleanupRequired }
      retained.server.stop()
      retained.credential.clear()
      try cleanupFailedClone(
        retained.plan,
        target: retained.cloneTarget,
        scope: retained.scope
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

  private func gitArguments(_ operationArguments: [String], repositoryURL: URL) -> [String] {
    let helper = shellQuote(brokerExecutableURL.path)
    let repositoryHTTPKey = "http.\(repositoryURL.absoluteString)"
    return [
      "-c", "credential.helper=",
      "-c", "credential.helper=!\(helper) git-credential",
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
    ] + operationArguments
  }

  private func operationArguments(
    _ plan: ValidatedGitOperationPlan,
    cloneTarget: CloneTargetHandle?,
    effectiveGitDirectory: URL?
  ) -> [String] {
    switch plan.request {
    case .clone:
      guard let cloneTarget else { return plan.arguments }
      let stagingURL = plan.targetURL.deletingLastPathComponent()
        .appendingPathComponent(cloneTarget.currentEntryName, isDirectory: true)
      return ["clone", "--", plan.repositoryURL.absoluteString, stagingURL.path]
    case .fetch:
      guard let effectiveGitDirectory else { return plan.arguments }
      return [
        "--git-dir=\(effectiveGitDirectory.path)",
        "--work-tree=\(plan.targetURL.path)",
        "fetch", "--prune", "--", plan.repositoryURL.absoluteString,
        "+refs/heads/*:refs/remotes/origin/*",
      ]
    case .push(_, let branch):
      guard let effectiveGitDirectory else { return plan.arguments }
      return [
        "--git-dir=\(effectiveGitDirectory.path)",
        "--work-tree=\(plan.targetURL.path)",
        "push", "--porcelain", "--", plan.repositoryURL.absoluteString,
        "HEAD:refs/heads/\(branch)",
      ]
    }
  }

  private func prepareEffectiveGitDirectory(
    _ plan: ValidatedGitOperationPlan,
    in temporaryDirectory: URL
  ) throws -> URL? {
    if case .clone = plan.request { return nil }
    let source = plan.targetURL.appendingPathComponent(".git", isDirectory: true)
    let effective = temporaryDirectory.appendingPathComponent("effective.git", isDirectory: true)
    try FileManager.default.createDirectory(at: effective, withIntermediateDirectories: false)
    guard chmod(effective.path, S_IRWXU) == 0 else { throw GitCommandRunnerError.launchFailed }
    let safeConfiguration = Data(
      """
      [core]
        repositoryformatversion = 0
        bare = false
      """.utf8
    )
    let effectiveConfiguration = effective.appendingPathComponent("config")
    try safeConfiguration.write(to: effectiveConfiguration, options: .atomic)
    guard chmod(effectiveConfiguration.path, S_IRUSR) == 0,
      chflags(effectiveConfiguration.path, UInt32(UF_IMMUTABLE)) == 0
    else { throw GitCommandRunnerError.launchFailed }
    for directoryName in ["objects", "refs"] {
      let sourceURL = source.appendingPathComponent(directoryName, isDirectory: true)
      let destinationURL = effective.appendingPathComponent(directoryName, isDirectory: true)
      if FileManager.default.fileExists(atPath: sourceURL.path) {
        try FileManager.default.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
      } else {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
      }
    }
    for fileName in ["HEAD", "packed-refs", "shallow"] {
      let sourceURL = source.appendingPathComponent(fileName)
      guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
      var information = stat()
      guard lstat(sourceURL.path, &information) == 0,
        information.st_mode & S_IFMT == S_IFREG,
        information.st_size >= 0,
        information.st_size <= 8 * 1_024 * 1_024
      else { throw GitCommandRunnerError.launchFailed }
      try Data(contentsOf: sourceURL).write(
        to: effective.appendingPathComponent(fileName),
        options: .atomic
      )
    }
    if !FileManager.default.fileExists(atPath: effective.appendingPathComponent("HEAD").path) {
      try Data("ref: refs/heads/main\n".utf8).write(to: effective.appendingPathComponent("HEAD"))
    }
    return effective
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
      "NO_PROXY": "*",
      "no_proxy": "*",
    ], directory)
  }

  private func removeIsolatedDirectory(_ directory: URL) {
    let configuration = directory.appendingPathComponent("effective.git/config")
    _ = chflags(configuration.path, 0)
    _ = chmod(configuration.path, S_IRUSR | S_IWUSR)
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
      _ = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
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
    var information = stat()
    guard targetDescriptor >= 0, fstat(targetDescriptor, &information) == 0,
      information.st_mode & S_IFMT == S_IFDIR,
      FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
        == createdIdentity
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
  }

  private func cleanupFailedClone(
    _ plan: ValidatedGitOperationPlan,
    target: CloneTargetHandle?,
    scope: AuthorizedGitHubRepositoryScope
  ) throws {
    guard case .clone = plan.request, let target else { return }
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
    try removeDirectoryContents(openedForCleanup)
    guard unlinkat(target.parentDescriptor, quarantineName, AT_REMOVEDIR) == 0 else {
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

  private func removeDirectoryContents(_ descriptor: Int32) throws {
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
          try removeDirectoryContents(child)
          close(child)
        } catch {
          close(child)
          throw error
        }
        guard unlinkat(descriptor, quarantinedName, AT_REMOVEDIR) == 0 else {
          throw GitCommandRunnerError.cleanupRequired
        }
      } else if information.st_mode & S_IFMT == S_IFREG {
        guard information.st_nlink == 1 else { throw GitCommandRunnerError.cleanupRequired }
        let file = openat(descriptor, quarantinedName, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw GitCommandRunnerError.cleanupRequired }
        var opened = stat()
        let matched = fstat(file, &opened) == 0
          && FileIdentity(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino))
            == FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
        let cleared = matched && ftruncate(file, 0) == 0
        close(file)
        guard cleared else {
          throw GitCommandRunnerError.cleanupRequired
        }
        guard unlinkat(descriptor, quarantinedName, 0) == 0 else {
          throw GitCommandRunnerError.cleanupRequired
        }
      } else if information.st_mode & S_IFMT == S_IFLNK {
        guard unlinkat(descriptor, quarantinedName, 0) == 0 else {
          throw GitCommandRunnerError.cleanupRequired
        }
      } else {
        throw GitCommandRunnerError.cleanupRequired
      }
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
        let data = try SocketLine.read(descriptor, maximumBytes: 32_768, timeoutMilliseconds: 5_000)
        let request = try JSONDecoder().decode(GitCredentialWireRequest.self, from: data)
        let response = try conversation(action: request.action, input: request.input)
        try SocketLine.write(JSONEncoder().encode(response), to: descriptor)
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
