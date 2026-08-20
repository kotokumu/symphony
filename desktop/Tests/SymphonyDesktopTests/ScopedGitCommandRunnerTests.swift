import Darwin
import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit
@testable import SymphonyCredentialBrokerProtocol

final class ScopedGitCommandRunnerTests: XCTestCase {
  func testLaunchesWithIsolatedCredentialFreeEnvironmentAndAuthorizedURL() async throws {
    let fixture = try makeFixture()
    let executable = try makeExecutable(
      """
      #!/bin/sh
      printf '%s\n' "$@"
      env
      exit 0
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: URL(fileURLWithPath: "/Applications/Symphony.app/Contents/Helpers/SymphonyCredentialBroker"),
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false
    )
    let source = SecureSecretBuffer(copying: Data("never-print-this-token".utf8))
    defer { source.clear() }

    let result = try await runner.run(.clone(targetName: "issue-7"), in: fixture.scope) {
      OperationCredential(copying: source)
    }

    XCTAssertTrue(result.output.contains("https://github.com/octo/repo"))
    XCTAssertTrue(result.output.contains("GIT_CONFIG_NOSYSTEM=1"))
    XCTAssertTrue(result.output.contains("GIT_CONFIG_GLOBAL=/dev/null"))
    XCTAssertFalse(result.output.contains("never-print-this-token"))
    XCTAssertFalse(result.output.lowercased().contains("http_proxy"))
    XCTAssertFalse(result.output.contains("GITHUB_TOKEN"))
    XCTAssertFalse(result.output.contains("SYMPHONY_GIT_HELPER_PORT"))
    XCTAssertFalse(result.output.contains("SYMPHONY_GIT_HELPER_NONCE"))
  }

  func testRemovesBrokerCreatedPartialCloneAfterFailure() async throws {
    let fixture = try makeFixture()
    let executable = try makeExecutable(
      """
      #!/bin/sh
      for argument in "$@"; do target="$argument"; done
      mkdir -p "$target"
      echo failed >&2
      exit 2
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "partial"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected Git failure")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .gitFailed)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("partial").path))
  }

  func testBoundsOutputAndReturnsATypedFailure() async throws {
    let fixture = try makeFixture()
    let executable = try makeExecutable(
      """
      #!/bin/sh
      yes x | head -c 70000
      exit 0
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "overflow"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected bounded output failure")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .gitOutputTooLarge)
      XCTAssertLessThanOrEqual(error.failure.message.utf8.count, 65_700)
    }
  }

  func testDoesNotDeleteAReplacementAtTheFailedClonePath() async throws {
    let fixture = try makeFixture()
    let ready = fixture.root.appendingPathComponent("ready")
    let release = fixture.root.appendingPathComponent("release")
    let executable = try makeExecutable(
      """
      #!/bin/sh
      touch "\(ready.path)"
      while [ ! -e "\(release.path)" ]; do sleep 0.01; done
      exit 2
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }
    let operation = Task {
      try await runner.run(.clone(targetName: "partial"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
    }
    try await waitForFile(ready)
    let target = fixture.root.appendingPathComponent("partial", isDirectory: true)
    let original = fixture.root.appendingPathComponent("original-partial", isDirectory: true)
    try FileManager.default.moveItem(at: target, to: original)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try Data("sentinel".utf8).write(to: target.appendingPathComponent("keep"))
    FileManager.default.createFile(atPath: release.path, contents: Data())

    do {
      _ = try await operation.value
      XCTFail("Expected cleanup-required failure")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    XCTAssertEqual(
      try Data(contentsOf: target.appendingPathComponent("keep")),
      Data("sentinel".utf8)
    )
    do {
      try await runner.stopRetainedOperation()
      XCTFail("Expected replacement identity to keep cleanup blocked")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    try FileManager.default.removeItem(at: target)
    try FileManager.default.moveItem(at: original, to: target)
    try await runner.stopRetainedOperation()
  }

  func testDoesNotDeleteAReplacementInsertedAfterCleanupIdentityVerification() async throws {
    let fixture = try makeFixture()
    let target = fixture.root.appendingPathComponent("cleanup-race", isDirectory: true)
    let original = fixture.root.appendingPathComponent("cleanup-race-original", isDirectory: true)
    let replacement = CloneCleanupReplacement(target: target, original: original)
    let executable = try makeExecutable("#!/bin/sh\nexit 2\n")
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeCloneCleanup: { replacement.replace() }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "cleanup-race"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected cleanup-required failure")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }

    XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("keep")), Data("sentinel".utf8))
  }

  func testStopAtFinalPreparationBarrierPreventsLaunch() async throws {
    let fixture = try makeFixture()
    let marker = fixture.root.appendingPathComponent("launched")
    let executable = try makeExecutable("#!/bin/sh\ntouch \"\(marker.path)\"\n")
    let gate = GitLaunchGate()
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeLaunch: { await gate.pause() }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }
    let operation = Task {
      try await runner.run(.clone(targetName: "cancelled-late"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
    }
    await gate.waitUntilPaused()
    let stop = Task { try await runner.stopRetainedOperation() }
    let stopWasRequested = await runner.waitUntilStopRequested()
    XCTAssertTrue(stopWasRequested)
    await gate.resume()
    do {
      _ = try await operation.value
      XCTFail("Expected stop admission to reject launch")
    } catch is CancellationError {}
    try await stop.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testRepositoryConfigurationReplacementAtFinalLaunchBarrierPreventsFetch() async throws {
    let fixture = try makeFixture()
    let repository = try makeRepository(in: fixture.root)
    let marker = fixture.root.appendingPathComponent("fetch-launched")
    let executable = try makeExecutable("#!/bin/sh\ntouch \"\(marker.path)\"\n")
    let gate = GitLaunchGate()
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeLaunch: { await gate.pause() }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    let credentialRequests = CredentialRequestCounter()
    defer { source.clear() }
    let operation = Task {
      try await runner.run(.fetch(repositoryName: repository.lastPathComponent), in: fixture.scope) {
        credentialRequests.increment()
        OperationCredential(copying: source)
      }
    }
    await gate.waitUntilPaused()
    try Data(
      "[remote \"origin\"]\nurl = https://github.com/attacker/repository\n".utf8
    ).write(to: repository.appendingPathComponent(".git/config"), options: .atomic)
    await gate.resume()

    do {
      _ = try await operation.value
      XCTFail("Expected final trust validation to reject the replacement")
    } catch let error as GitRepositoryTrustError {
      switch error {
      case .repositoryMismatch, .filesystemChanged: break
      default: XCTFail("Unexpected trust error: \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(credentialRequests.value, 0)
  }

  func testEveryFilesystemAuthorityIsRevalidatedAtTheFinalLaunchBarrier() async throws {
    for mutation in FinalTrustMutation.allCases {
      let fixture = try makeFixture()
      let repository = try makeRepository(in: fixture.root)
      let marker = FileManager.default.temporaryDirectory
        .appendingPathComponent("git-final-marker-\(UUID().uuidString)")
      addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
      let executable = try makeExecutable("#!/bin/sh\ntouch \"\(marker.path)\"\n")
      let gate = GitLaunchGate()
      let requests = CredentialRequestCounter()
      let runner = ScopedGitCommandRunner(
        gitExecutableURL: executable,
        brokerExecutableURL: executable,
        operationTimeout: 2,
        wrapsGitInBrokerExecutable: false,
        beforeLaunch: { await gate.pause() }
      )
      let source = SecureSecretBuffer(copying: Data("token".utf8))
      defer { source.clear() }
      let request: GitRepositoryCapabilityRequest = mutation == .preparedClone
        ? .clone(targetName: "prepared-clone")
        : .fetch(repositoryName: repository.lastPathComponent)
      let operation = Task {
        try await runner.run(request, in: fixture.scope) {
          requests.increment()
          return OperationCredential(copying: source)
        }
      }
      await gate.waitUntilPaused()

      let backup = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("git-final-backup-\(UUID().uuidString)", isDirectory: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: backup) }
      switch mutation {
      case .workspaceRoot:
        try FileManager.default.moveItem(at: fixture.root, to: backup)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
      case .repositoryDirectory:
        try FileManager.default.moveItem(at: repository, to: backup)
        _ = try makeRepository(in: fixture.root)
      case .metadataDirectory:
        let metadata = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.moveItem(at: metadata, to: backup)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        try writeRepositoryConfiguration(to: metadata.appendingPathComponent("config"))
      case .preparedClone:
        let target = fixture.root.appendingPathComponent("prepared-clone", isDirectory: true)
        try FileManager.default.moveItem(at: target, to: backup)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      }
      await gate.resume()

      do {
        _ = try await operation.value
        XCTFail("Expected \(mutation) replacement rejection")
      } catch let error as GitRepositoryTrustError {
        guard mutation != .preparedClone else {
          XCTFail("Expected retained clone cleanup, got \(error)")
          continue
        }
        switch error {
        case .filesystemChanged: break
        default: XCTFail("Unexpected trust error for \(mutation): \(error)")
        }
      } catch let error as GitCommandRunnerError {
        XCTAssertEqual(mutation, .preparedClone)
        XCTAssertEqual(error.failure.category, .cleanupRequired)
      }
      XCTAssertEqual(requests.value, 0)
      XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

      if mutation == .preparedClone {
        let target = fixture.root.appendingPathComponent("prepared-clone", isDirectory: true)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: backup, to: target)
        try await runner.stopRetainedOperation()
      }
    }
  }

  func testInheritedSocketCapabilityWorksThroughTheRealBrokerHelperExecutable() async throws {
    let fixture = try makeFixture()
    let broker = try brokerExecutable()
    let executable = try makeExecutable(
      """
      #!/bin/sh
      request="$HOME/credential-request"
      printf 'protocol=https\nhost=github.com\npath=octo/repo\n\n' > "$request"
      exec /usr/bin/git \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" credential fill < "$request"
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: broker,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: true
    )
    let source = SecureSecretBuffer(copying: Data("socket-canary-token".utf8))
    defer { source.clear() }

    let result = try await runner.run(.clone(targetName: "helper"), in: fixture.scope) {
      OperationCredential(copying: source)
    }

    XCTAssertTrue(result.output.contains("username=x-access-token"))
    XCTAssertFalse(result.output.contains("socket-canary-token"))
    XCTAssertTrue(result.output.contains("[REDACTED]"))
  }

  func testRedactsEveryCredentialRepresentation() {
    let source = SecureSecretBuffer(copying: Data("canary-token".utf8))
    let credential = OperationCredential(copying: source)
    source.clear()
    let basic = Data("x-access-token:canary-token".utf8).base64EncodedString()
    let output = credential.redact(
      "canary-token \(Data("canary-token".utf8).base64EncodedString()) Basic \(basic)"
    )
    XCTAssertFalse(output.contains("canary-token"))
    XCTAssertFalse(output.contains(basic))
    XCTAssertTrue(output.contains("[REDACTED]"))
    credential.clear()
  }

  func testLockPreemptsPreparationBeforeCredentialCanLaunchGit() async throws {
    let fixture = try makeFixture()
    let marker = fixture.root.appendingPathComponent("launched")
    let executable = try makeExecutable(
      """
      #!/bin/sh
      touch "\(marker.path)"
      exit 0
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false
    )
    let gate = CredentialAcquisitionGate()
    let operation = Task {
      try await runner.run(.clone(targetName: "cancelled"), in: fixture.scope) {
        await gate.acquire()
      }
    }
    await gate.waitUntilRequested()
    let stop = Task { try await runner.stopRetainedOperation() }
    let stopWasRequested = await runner.waitUntilStopRequested()
    XCTAssertTrue(stopWasRequested)
    await gate.release(OperationCredential(copying: SecureSecretBuffer(copying: Data("token".utf8))))

    do {
      _ = try await operation.value
      XCTFail("Expected cancelled preparation")
    } catch {}
    try await stop.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testStopWaitsForActiveGitParentAndDescendantProcessGroup() async throws {
    let fixture = try makeFixture()
    let parentPIDFile = fixture.root.appendingPathComponent("git-parent-pid")
    let childPIDFile = fixture.root.appendingPathComponent("git-child-pid")
    let executable = try makeExecutable(
      """
      #!/bin/sh
      sleep 0.1
      echo $$ > "\(parentPIDFile.path)"
      sleep 60 &
      child=$!
      echo $child > "\(childPIDFile.path)"
      wait $child
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 60,
      stopTimeout: 0.5,
      wrapsGitInBrokerExecutable: false
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }
    let operation = Task {
      try await runner.run(.clone(targetName: "active"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
    }
    try await waitForFile(parentPIDFile)
    try await waitForFile(childPIDFile)
    let parentPID = try XCTUnwrap(Int32(String(contentsOf: parentPIDFile).trimmingCharacters(in: .whitespacesAndNewlines)))
    let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile).trimmingCharacters(in: .whitespacesAndNewlines)))

    try await runner.stopRetainedOperation()
    do {
      _ = try await operation.value
      XCTFail("Expected stopped Git operation to fail")
    } catch {}

    XCTAssertFalse(processExists(parentPID))
    XCTAssertFalse(processExists(childPID))
  }

  private func makeFixture() throws -> (root: URL, scope: AuthorizedGitHubRepositoryScope) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-git-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let authorization = GitHubRepositoryAuthorization(
      appID: 10,
      installationID: 20,
      repositoryID: 30,
      repositoryFullName: "octo/repo",
      repositoryURL: URL(string: "https://github.com/octo/repo")!,
      workspacesRoot: root
    )
    return (root, try AuthorizedGitHubRepositoryScope(authorization, storedAppID: 10))
  }

  private func makeRepository(in root: URL) throws -> URL {
    let repository = root.appendingPathComponent("existing", isDirectory: true)
    let metadata = repository.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    try writeRepositoryConfiguration(to: metadata.appendingPathComponent("config"))
    return repository
  }

  private func writeRepositoryConfiguration(to url: URL) throws {
    try Data(
      """
      [core]
        repositoryformatversion = 0
        bare = false
      [remote "origin"]
        url = https://github.com/octo/repo
        fetch = +refs/heads/*:refs/remotes/origin/*
      """.utf8
    ).write(to: url)
  }

  private func makeExecutable(_ source: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-fake-git-\(UUID().uuidString)")
    try Data(source.utf8).write(to: url)
    XCTAssertEqual(chmod(url.path, 0o700), 0)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func waitForFile(_ url: URL) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  private func brokerExecutable() throws -> URL {
    let starts = [
      Bundle(for: ScopedGitCommandRunnerTests.self).bundleURL,
      URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
    ]
    for start in starts {
      var directory = start
      for _ in 0..<8 {
        let candidate = directory.appendingPathComponent("SymphonyCredentialBroker")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        directory.deleteLastPathComponent()
      }
    }
    throw GitCommandRunnerError.launchFailed
  }

  private func processExists(_ pid: Int32) -> Bool {
    let result = Darwin.kill(pid, 0)
    return result == 0 || errno == EPERM
  }
}

private enum FinalTrustMutation: CaseIterable, Equatable {
  case workspaceRoot
  case repositoryDirectory
  case metadataDirectory
  case preparedClone
}

private final class CredentialRequestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

private final class CloneCleanupReplacement: @unchecked Sendable {
  private let lock = NSLock()
  private let target: URL
  private let original: URL
  private var replaced = false

  init(target: URL, original: URL) {
    self.target = target
    self.original = original
  }

  func replace() {
    lock.withLock {
      guard !replaced else { return }
      replaced = true
      try? FileManager.default.moveItem(at: target, to: original)
      try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      try? Data("sentinel".utf8).write(to: target.appendingPathComponent("keep"))
    }
  }
}

private actor GitLaunchGate {
  private var paused = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func pause() async {
    paused = true
    pauseWaiters.forEach { $0.resume() }
    pauseWaiters.removeAll()
    await withCheckedContinuation { resumeContinuation = $0 }
  }

  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { pauseWaiters.append($0) }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

private actor CredentialAcquisitionGate {
  private var requested = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var credentialContinuation: CheckedContinuation<OperationCredential, Never>?

  func acquire() async -> OperationCredential {
    requested = true
    requestWaiters.forEach { $0.resume() }
    requestWaiters.removeAll()
    return await withCheckedContinuation { credentialContinuation = $0 }
  }

  func waitUntilRequested() async {
    if requested { return }
    await withCheckedContinuation { requestWaiters.append($0) }
  }

  func release(_ credential: OperationCredential) {
    credentialContinuation?.resume(returning: credential)
    credentialContinuation = nil
  }
}
