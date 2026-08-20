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
      printf 'TEMP_HOME=%s\n' "$HOME"
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
    XCTAssertTrue(result.output.contains("http.proxy="))
    XCTAssertTrue(result.output.contains("http.sslVerify=true"))
    XCTAssertTrue(result.output.contains("http.https://github.com/octo/repo.proxy="))
    XCTAssertTrue(result.output.contains("protocol.allow=never"))
    XCTAssertTrue(result.output.contains("protocol.https.allow=always"))
    XCTAssertTrue(result.output.contains("NO_PROXY=*"))
    XCTAssertFalse(result.output.contains("never-print-this-token"))
    XCTAssertFalse(result.output.lowercased().contains("http_proxy"))
    XCTAssertFalse(result.output.contains("GITHUB_TOKEN"))
    XCTAssertFalse(result.output.contains("SYMPHONY_GIT_HELPER_PORT"))
    XCTAssertFalse(result.output.contains("SYMPHONY_GIT_HELPER_NONCE"))
    let temporaryHome = try XCTUnwrap(
      result.output.split(separator: "\n")
        .first { $0.hasPrefix("TEMP_HOME=") }
        .map { String($0.dropFirst("TEMP_HOME=".count)) }
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryHome))
    try assertNoCredentialRepresentations("never-print-this-token", under: fixture.root)
  }

  func testRemovesBrokerCreatedPartialCloneAfterFailure() async throws {
    let fixture = try makeFixture()
    let external = fixture.root.appendingPathComponent("external-sentinel")
    try Data("preserve-me".utf8).write(to: external)
    let executable = try makeExecutable(
      """
      #!/bin/sh
      for argument in "$@"; do target="$argument"; done
      mkdir -p "$target/nested"
      printf partial > "$target/nested/data"
      ln -s "\(external.path)" "$target/link"
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
    XCTAssertEqual(try Data(contentsOf: external), Data("preserve-me".utf8))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        .contains { $0.hasPrefix(".symphony-") }
    )
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
    let target = try findCloneStagingDirectory(in: fixture.root)
    let original = fixture.root.appendingPathComponent("original-\(target.lastPathComponent)", isDirectory: true)
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
    let replacement = CloneCleanupReplacement(root: fixture.root)
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

    let target = try replacement.replacementURL()
    XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("keep")), Data("sentinel".utf8))
  }

  func testCloneTargetReplacementBetweenCreationAndOpenIsRetainedForSafeRetry() async throws {
    let fixture = try makeFixture()
    let replacement = DescriptorEntryReplacement(targetEntry: nil)
    let executable = try makeExecutable("#!/bin/sh\nexit 0\n")
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeCloneTargetOpen: { descriptor, name in
        replacement.replace(parentDescriptor: descriptor, name: name)
      }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "published"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected clone staging replacement rejection")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    let replacementURL = try replacement.replacementURL(in: fixture.root)
    XCTAssertEqual(try Data(contentsOf: replacementURL.appendingPathComponent("keep")), Data("sentinel".utf8))
    try replacement.restoreOriginal(in: fixture.root)
    try await runner.stopRetainedOperation()
    XCTAssertFalse(FileManager.default.fileExists(atPath: replacementURL.path))
  }

  func testFailedCloneCleanupRejectsExternalHardLinksAndRetriesAfterRemoval() async throws {
    let fixture = try makeFixture()
    let external = fixture.root.appendingPathComponent("external-hard-link")
    try Data("external-sentinel".utf8).write(to: external)
    let executable = try makeExecutable(
      """
      #!/bin/sh
      for argument in "$@"; do target="$argument"; done
      ln "\(external.path)" "$target/linked"
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
      _ = try await runner.run(.clone(targetName: "hard-link"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected retained cleanup for a multiply linked inode")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    XCTAssertEqual(try Data(contentsOf: external), Data("external-sentinel".utf8))
    let quarantine = try findCloneStagingDirectory(in: fixture.root)
    let linkedEntry = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(".symphony-cleared-") }
    )
    try FileManager.default.removeItem(at: linkedEntry)
    try await runner.stopRetainedOperation()
    XCTAssertEqual(try Data(contentsOf: external), Data("external-sentinel".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
  }

  func testNestedCleanupReplacementIsPreservedAndCleanupCoalescesIntoRetry() async throws {
    let fixture = try makeFixture()
    let replacement = DescriptorEntryReplacement(targetEntry: "nested")
    let executable = try makeExecutable(
      """
      #!/bin/sh
      for argument in "$@"; do target="$argument"; done
      mkdir -p "$target/nested"
      printf partial > "$target/nested/data"
      exit 2
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeNestedCloneCleanup: { descriptor, name in
        replacement.replace(parentDescriptor: descriptor, name: name)
      }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "nested-race"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected nested cleanup replacement rejection")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    let quarantine = try findCloneStagingDirectory(in: fixture.root)
    let replacementURL = try replacement.replacementURL(in: quarantine)
    XCTAssertEqual(try Data(contentsOf: replacementURL.appendingPathComponent("keep")), Data("sentinel".utf8))
    try replacement.restoreOriginal(in: quarantine)
    try await runner.stopRetainedOperation()
    XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
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
        return OperationCredential(copying: source)
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

  func testGitReadsOnlyTheBrokerEffectiveConfigurationAfterFinalValidation() async throws {
    let fixture = try makeFixture()
    let repository = try makeRepository(in: fixture.root)
    let effectiveMutation = EffectiveConfigurationMutation()
    let executable = try makeExecutable(
      """
      #!/bin/sh
      for argument in "$@"; do
        case "$argument" in --git-dir=*) git_dir="${argument#--git-dir=}" ;; esac
      done
      printf 'EFFECTIVE=%s\n' "$git_dir"
      /usr/bin/git --git-dir="$git_dir" config --get-urlmatch \
        http.curloptResolve https://github.com/octo/repo/info/refs || true
      /usr/bin/git --git-dir="$git_dir" config --get-urlmatch \
        http.sslCAInfo https://github.com/octo/repo/info/refs || true
      exit 0
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      afterEffectiveConfigurationPrepared: { effectiveDirectory in
        if let effectiveDirectory {
          effectiveMutation.attempt(
            effectiveDirectory.appendingPathComponent("config")
          )
        }
        try? Data(
          """
          [core]
            repositoryformatversion = 0
            bare = false
          [remote "origin"]
            url = https://github.com/octo/repo
            fetch = +refs/heads/*:refs/remotes/origin/*
          [http "https://github.com/octo/repo/info"]
            curloptResolve = +github.com:443:127.0.0.1
            sslCAInfo = /tmp/attacker-ca.pem
          """.utf8
        ).write(to: repository.appendingPathComponent(".git/config"), options: .atomic)
      }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    let result = try await runner.run(.fetch(repositoryName: "existing"), in: fixture.scope) {
      OperationCredential(copying: source)
    }

    XCTAssertTrue(result.output.contains("EFFECTIVE="))
    XCTAssertFalse(result.output.contains("127.0.0.1"))
    XCTAssertFalse(result.output.contains("attacker-ca.pem"))
    XCTAssertFalse(result.output.contains(repository.appendingPathComponent(".git").path))
    XCTAssertTrue(effectiveMutation.wasRejected)
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
        let target = try findCloneStagingDirectory(in: fixture.root)
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
        let target = try findCloneStagingDirectory(in: fixture.root)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: backup, to: target)
        try await runner.stopRetainedOperation()
      }
    }
  }

  func testInheritedSocketCapabilityWorksThroughTheRealBrokerHelperExecutable() async throws {
    let fixture = try makeFixture()
    let broker = try brokerExecutable()
    let ready = fixture.root.appendingPathComponent("credential-used")
    let release = fixture.root.appendingPathComponent("credential-release")
    let homePath = fixture.root.appendingPathComponent("temporary-home-path")
    let processIDPath = fixture.root.appendingPathComponent("credential-process-id")
    let executable = try makeExecutable(
      """
      #!/bin/sh
      request="$HOME/credential-request"
      printf 'protocol=https\nhost=github.com\npath=octo/repo\n\n' > "$request"
      credential_output=$(/usr/bin/git \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" credential fill < "$request")
      printf '%s' "$HOME" > "\(homePath.path)"
      printf '%s' "$$" > "\(processIDPath.path)"
      touch "\(ready.path)"
      while [ ! -e "\(release.path)" ]; do sleep 0.01; done
      printf '%s\n' "$credential_output"
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

    let operation = Task {
      try await runner.run(.clone(targetName: "helper"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
    }
    try await waitForFile(ready)
    let temporaryHome = URL(
      fileURLWithPath: try String(contentsOf: homePath, encoding: .utf8)
    )
    try assertNoCredentialRepresentations("socket-canary-token", under: fixture.root)
    try assertNoCredentialRepresentations("socket-canary-token", under: temporaryHome)
    let processID = try XCTUnwrap(
      Int32(String(contentsOf: processIDPath, encoding: .utf8))
    )
    let processListing = try processOutput(
      executable: URL(fileURLWithPath: "/bin/ps"),
      arguments: ["eww", "-p", String(processID)]
    )
    XCTAssertFalse(processListing.contains("socket-canary-token"))
    FileManager.default.createFile(atPath: release.path, contents: Data())
    let result = try await operation.value

    XCTAssertTrue(result.output.contains("username=x-access-token"))
    XCTAssertFalse(result.output.contains("socket-canary-token"))
    XCTAssertTrue(result.output.contains("[REDACTED]"))
  }

  func testRedactsEveryCredentialRepresentation() {
    let source = SecureSecretBuffer(copying: Data("canary-token".utf8))
    let credential = OperationCredential(copying: source)
    source.clear()
    let basic = Data("x-access-token:canary-token".utf8).base64EncodedString()
    let hex = Data("canary-token".utf8).map { String(format: "%02x", $0) }.joined()
    let output = credential.redact(
      "canary-token \(Data("canary-token".utf8).base64EncodedString()) \(hex) Basic \(basic)"
    )
    XCTAssertFalse(output.contains("canary-token"))
    XCTAssertFalse(output.contains(basic))
    XCTAssertFalse(output.contains(hex))
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
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected preparation cancellation error: \(error)")
    }
    try await stop.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testStopWaitsForActiveGitParentAndDescendantProcessGroup() async throws {
    let fixture = try makeFixture()
    let broker = try brokerExecutable()
    let parentPIDFile = fixture.root.appendingPathComponent("git-parent-pid")
    let childPIDFile = fixture.root.appendingPathComponent("git-child-pid")
    let processReadyFile = fixture.root.appendingPathComponent("git-process-ready")
    let processReleaseFile = fixture.root.appendingPathComponent("git-process-release")
    let groupObservation = ProcessGroupObservation()
    let executable = try makeExecutable(
      """
      #!/bin/sh
      touch "\(processReadyFile.path)"
      while [ ! -e "\(processReleaseFile.path)" ]; do sleep 0.01; done
      echo $$ > "\(parentPIDFile.path)"
      sleep 60 &
      child=$!
      echo $child > "\(childPIDFile.path)"
      wait $child
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: broker,
      operationTimeout: 60,
      stopTimeout: 0.5,
      wrapsGitInBrokerExecutable: true,
      afterProcessGroupEstablished: { groupObservation.record($0) }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }
    let operation = Task {
      try await runner.run(.clone(targetName: "active"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
    }
    let observedParentPID = try await groupObservation.waitForProcessID()
    XCTAssertEqual(Darwin.getpgid(observedParentPID), observedParentPID)
    try await waitForFile(processReadyFile)
    FileManager.default.createFile(atPath: processReleaseFile.path, contents: Data())
    try await waitForFile(parentPIDFile)
    try await waitForFile(childPIDFile)
    let parentPID = try XCTUnwrap(Int32(String(contentsOf: parentPIDFile).trimmingCharacters(in: .whitespacesAndNewlines)))
    let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile).trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertEqual(parentPID, observedParentPID)
    XCTAssertEqual(Darwin.getpgid(parentPID), parentPID)
    XCTAssertEqual(Darwin.getpgid(childPID), parentPID)

    try await runner.stopRetainedOperation()
    do {
      _ = try await operation.value
      XCTFail("Expected stopped Git operation to fail")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .gitFailed)
    } catch {
      XCTFail("Unexpected stopped operation error: \(error)")
    }

    XCTAssertFalse(processExists(parentPID))
    XCTAssertFalse(processExists(childPID))
  }

  func testFailedProcessGroupStopRetainsRuntimeUntilProductionRetrySucceeds() async throws {
    let fixture = try makeFixture()
    let broker = try brokerExecutable()
    let ready = fixture.root.appendingPathComponent("retained-ready")
    let release = fixture.root.appendingPathComponent("retained-release")
    let parentPIDFile = fixture.root.appendingPathComponent("retained-parent")
    let childPIDFile = fixture.root.appendingPathComponent("retained-child")
    let executable = try makeExecutable(
      """
      #!/bin/sh
      touch "\(ready.path)"
      while [ ! -e "\(release.path)" ]; do sleep 0.01; done
      echo $$ > "\(parentPIDFile.path)"
      sleep 60 &
      child=$!
      echo $child > "\(childPIDFile.path)"
      wait $child
      """
    )
    let controller = FailOnceGitProcessGroupController()
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: broker,
      operationTimeout: 60,
      stopTimeout: 0.05,
      wrapsGitInBrokerExecutable: true,
      processGroupController: controller.controller
    )
    let source = SecureSecretBuffer(copying: Data("retained-token".utf8))
    defer { source.clear() }
    let operation = Task {
      try await runner.run(.clone(targetName: "retained"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
    }
    try await waitForFile(ready)
    FileManager.default.createFile(atPath: release.path, contents: Data())
    try await waitForFile(parentPIDFile)
    try await waitForFile(childPIDFile)
    let parentPID = try XCTUnwrap(Int32(String(contentsOf: parentPIDFile).trimmingCharacters(in: .whitespacesAndNewlines)))
    let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile).trimmingCharacters(in: .whitespacesAndNewlines)))

    do {
      try await runner.stopRetainedOperation()
      XCTFail("Expected the first group stop to fail")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    do {
      _ = try await runner.run(.clone(targetName: "replacement"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected retained ownership to block replacement")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    XCTAssertTrue(processExists(parentPID))
    XCTAssertTrue(processExists(childPID))

    controller.allowSignals()
    try await runner.stopRetainedOperation()
    do {
      _ = try await operation.value
      XCTFail("Expected stopped operation failure")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .gitFailed)
    }
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

  private func findCloneStagingDirectory(in root: URL) throws -> URL {
    let name = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(atPath: root.path)
        .first { $0.hasPrefix(".symphony-clone-") || $0.hasPrefix(".symphony-failed-clone-") }
    )
    return root.appendingPathComponent(name, isDirectory: true)
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

  private func processOutput(executable: URL, arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }

  private func processExists(_ pid: Int32) -> Bool {
    let result = Darwin.kill(pid, 0)
    return result == 0 || errno == EPERM
  }

  private func assertNoCredentialRepresentations(_ token: String, under root: URL) throws {
    let data = Data(token.utf8)
    let representations = [
      token,
      data.base64EncodedString(),
      data.map { String(format: "%02x", $0) }.joined(),
      "Bearer \(token)",
      "Basic \(Data("x-access-token:\(token)".utf8).base64EncodedString())",
    ]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return }
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
        values.isRegularFile == true,
        let contents = try? Data(contentsOf: url)
      else { continue }
      for representation in representations {
        XCTAssertNil(
          contents.range(of: Data(representation.utf8)),
          "Credential representation persisted at \(url.path)"
        )
      }
    }
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

private final class ProcessGroupObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var processID: Int32?

  func record(_ processID: Int32) {
    lock.withLock { self.processID = processID }
  }

  func waitForProcessID() async throws -> Int32 {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
      if let processID = lock.withLock({ processID }) { return processID }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw GitCommandRunnerError.launchFailed
  }
}

private final class EffectiveConfigurationMutation: @unchecked Sendable {
  private let lock = NSLock()
  private var rejected = false

  var wasRejected: Bool { lock.withLock { rejected } }

  func attempt(_ configuration: URL) {
    do {
      try Data("[http]\nproxy = https://attacker.test\n".utf8).write(
        to: configuration,
        options: .atomic
      )
      lock.withLock { rejected = false }
    } catch {
      lock.withLock { rejected = true }
    }
  }
}

private final class FailOnceGitProcessGroupController: @unchecked Sendable {
  private let lock = NSLock()
  private var signalsAllowed = false

  var controller: GitProcessGroupController {
    GitProcessGroupController(
      exists: { processID in
        let result = Darwin.kill(-processID, 0)
        return result == 0 || errno == EPERM
      },
      signal: { [weak self] processID, signal in
        guard let self, self.lock.withLock({ self.signalsAllowed }) else { return }
        if Darwin.kill(-processID, signal) != 0 { _ = Darwin.kill(processID, signal) }
      }
    )
  }

  func allowSignals() {
    lock.withLock { signalsAllowed = true }
  }
}

private final class CloneCleanupReplacement: @unchecked Sendable {
  private let lock = NSLock()
  private let root: URL
  private var target: URL?
  private var replaced = false

  init(root: URL) {
    self.root = root
  }

  func replace() {
    lock.withLock {
      guard !replaced else { return }
      guard let name = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        .first(where: { $0.hasPrefix(".symphony-clone-") })
      else { return }
      let target = root.appendingPathComponent(name, isDirectory: true)
      let original = root.appendingPathComponent("original-\(name)", isDirectory: true)
      try? FileManager.default.moveItem(at: target, to: original)
      try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      try? Data("sentinel".utf8).write(to: target.appendingPathComponent("keep"))
      self.target = target
      replaced = true
    }
  }

  func replacementURL() throws -> URL {
    try lock.withLock { try XCTUnwrap(target) }
  }
}

private final class DescriptorEntryReplacement: @unchecked Sendable {
  private let lock = NSLock()
  private let targetEntry: String?
  private var replacedName: String?

  init(targetEntry: String?) {
    self.targetEntry = targetEntry
  }

  func replace(parentDescriptor: Int32, name: String) {
    lock.withLock {
      guard replacedName == nil, targetEntry == nil || targetEntry == name else { return }
      let originalName = "\(name)-original"
      guard Darwin.renameat(parentDescriptor, name, parentDescriptor, originalName) == 0,
        Darwin.mkdirat(parentDescriptor, name, S_IRWXU) == 0
      else { return }
      let replacement = Darwin.openat(
        parentDescriptor,
        name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard replacement >= 0 else { return }
      defer { Darwin.close(replacement) }
      let file = Darwin.openat(
        replacement,
        "keep",
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
        S_IRUSR | S_IWUSR
      )
      guard file >= 0 else { return }
      var sentinel = Data("sentinel".utf8)
      _ = sentinel.withUnsafeMutableBytes { bytes in
        Darwin.write(file, bytes.baseAddress, bytes.count)
      }
      Darwin.close(file)
      replacedName = name
    }
  }

  func replacementURL(in parent: URL) throws -> URL {
    let name = try lock.withLock { try XCTUnwrap(replacedName) }
    return parent.appendingPathComponent(name, isDirectory: true)
  }

  func restoreOriginal(in parent: URL) throws {
    let name = try lock.withLock { try XCTUnwrap(replacedName) }
    let replacement = parent.appendingPathComponent(name, isDirectory: true)
    let original = parent.appendingPathComponent("\(name)-original", isDirectory: true)
    try FileManager.default.removeItem(at: replacement)
    try FileManager.default.moveItem(at: original, to: replacement)
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
