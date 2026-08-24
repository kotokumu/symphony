import Darwin
import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit
@testable import SymphonyCredentialBrokerProtocol

final class ScopedGitCommandRunnerTests: XCTestCase {
  func testCanonicalSandboxPathResolvesTheSystemTemporaryDirectoryAlias() {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    let canonical = ScopedGitCommandRunner.canonicalSandboxPath(temporaryPath)

    XCTAssertTrue(canonical.hasPrefix("/"))
    if temporaryPath.hasPrefix("/var/") {
      XCTAssertTrue(canonical.hasPrefix("/private/var/"), canonical)
    }
  }

  func testUnavailableGitFailsBeforeCredentialAcquisition() async throws {
    let fixture = try makeFixture()
    let credentialRequests = CredentialRequestCounter()
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: URL(fileURLWithPath: "/nonexistent/symphony-git")
    )

    do {
      _ = try await runner.run(.clone(targetName: "missing-git"), in: fixture.scope) {
        credentialRequests.increment()
        let source = SecureSecretBuffer(copying: Data("token".utf8))
        defer { source.clear() }
        return OperationCredential(copying: source)
      }
      XCTFail("Expected unavailable Git to fail")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .gitFailed)
    }
    XCTAssertEqual(credentialRequests.value, 0)
  }

  func testSandboxProfileAllowsOnlyTheBrokerOwnedLoopbackTunnel() {
    let profile = ScopedGitCommandRunner.sandboxProfile(proxyPort: 43_123)
    XCTAssertTrue(profile.contains("(deny default)"))
    XCTAssertTrue(profile.contains("(allow network-outbound"))
    XCTAssertTrue(profile.contains("(remote tcp \"localhost:43123\")"))
    XCTAssertTrue(profile.contains("(allow network* (socket-domain AF_UNIX))"))
    XCTAssertTrue(profile.contains("(allow file-write-data"))
    XCTAssertTrue(profile.contains("(vnode-type REGULAR-FILE)"))
    XCTAssertTrue(profile.contains("(allow file-write*"))
    XCTAssertTrue(profile.contains("(literal (param \"WRITE_ROOT\"))"))
    XCTAssertTrue(profile.contains("(subpath (param \"WRITE_ROOT\"))"))
    XCTAssertFalse(profile.contains("(allow default)"))
    XCTAssertFalse(profile.contains("github.com"))
  }

  func testGitHubProxyRejectsRequestsWithoutItsOperationLocalCredential() throws {
    let fixture = try makeFixture()
    let source = SecureSecretBuffer(copying: Data("github-token".utf8))
    defer { source.clear() }
    let credential = OperationCredential(copying: source)
    let proxy = try GitHubConnectProxy(scope: fixture.scope, credential: credential)
    defer { proxy.stop() }
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(proxy.port.bigEndian)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(connected, 0)
    let request = Data("GET /octo/repo.git/info/refs HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    let sent = request.withUnsafeBytes {
      Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
    }
    XCTAssertEqual(sent, request.count)
    var response = [UInt8](repeating: 0, count: 256)
    let count = Darwin.recv(descriptor, &response, response.count, 0)
    XCTAssertGreaterThan(count, 0)
    XCTAssertTrue(String(decoding: response.prefix(max(0, count)), as: UTF8.self).contains("403 Forbidden"))
  }

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
    XCTAssertTrue(result.output.contains("NO_PROXY="))
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

  func testFailedClonePreservesBrokerStagingAndBlocksRetryBeforeCredentialUse() async throws {
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
    let residue = try findCloneStagingDirectory(in: fixture.root)
    XCTAssertEqual(try Data(contentsOf: residue.appendingPathComponent("nested/data")), Data("partial".utf8))
    XCTAssertEqual(try Data(contentsOf: external), Data("preserve-me".utf8))
    let credentialRequests = CredentialRequestCounter()
    do {
      _ = try await runner.run(.clone(targetName: "retry"), in: fixture.scope) {
        credentialRequests.increment()
        return OperationCredential(copying: source)
      }
      XCTFail("Expected preserved staging to close admission")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    XCTAssertEqual(credentialRequests.value, 0)
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

  func testDurableCloneResidueBlocksAReplacementRunnerBeforeCredentialUse() async throws {
    let fixture = try makeFixture()
    let residue = fixture.root.appendingPathComponent(
      ".symphony-failed-clone-interrupted",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: residue, withIntermediateDirectories: false)
    let marker = fixture.root.appendingPathComponent("launched")
    let executable = try makeExecutable("#!/bin/sh\ntouch \"\(marker.path)\"\n")
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false
    )
    let credentialRequests = CredentialRequestCounter()
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "replacement"), in: fixture.scope) {
        credentialRequests.increment()
        return OperationCredential(copying: source)
      }
      XCTFail("Expected durable residue to close admission")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    XCTAssertEqual(credentialRequests.value, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  #if false // Superseded by fail-closed staging preservation tests below.
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

  func testCloneReplacementImmediatelyBeforePublishIsRejected() async throws {
    let fixture = try makeFixture()
    let replacement = DescriptorEntryReplacement(targetEntry: nil)
    let executable = try makeExecutable("#!/bin/sh\nexit 0\n")
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeClonePublish: { descriptor, name in
        replacement.replace(parentDescriptor: descriptor, name: name)
      }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "published"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected pre-publish identity rejection")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    let replacementURL = try replacement.replacementURL(in: fixture.root)
    XCTAssertEqual(try Data(contentsOf: replacementURL.appendingPathComponent("keep")), Data("sentinel".utf8))
    try replacement.restoreOriginal(in: fixture.root)
    try await runner.stopRetainedOperation()
  }

  func testCloneReplacementImmediatelyAfterPublishIsRejectedAndPreserved() async throws {
    let fixture = try makeFixture()
    let replacement = DescriptorEntryReplacement(targetEntry: "published")
    let executable = try makeExecutable("#!/bin/sh\nexit 0\n")
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      afterClonePublish: { descriptor, name in
        replacement.replace(parentDescriptor: descriptor, name: name)
      }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "published"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected post-publish identity rejection")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    let replacementURL = try replacement.replacementURL(in: fixture.root)
    XCTAssertEqual(try Data(contentsOf: replacementURL.appendingPathComponent("keep")), Data("sentinel".utf8))
    try replacement.restoreOriginal(in: fixture.root)
    try await runner.stopRetainedOperation()
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
    try await runner.stopRetainedOperation()
    XCTAssertEqual(try Data(contentsOf: external), Data("external-sentinel".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
  }

  func testCleanupDoesNotTruncateAHardLinkAddedImmediatelyBeforeUnlink() async throws {
    let fixture = try makeFixture()
    let external = fixture.root.appendingPathComponent("late-hard-link")
    let insertion = LateHardLinkInsertion(destination: external)
    let executable = try makeExecutable(
      """
      #!/bin/sh
      for argument in "$@"; do target="$argument"; done
      printf preserve-me > "$target/data"
      exit 2
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeDestructiveCloneCleanup: { descriptor, name in
        insertion.insert(from: descriptor, name: name)
      }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "late-link"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected retained cleanup after the late hard link")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    XCTAssertEqual(try Data(contentsOf: external), Data("preserve-me".utf8))
    try await runner.stopRetainedOperation()
    XCTAssertEqual(try Data(contentsOf: external), Data("preserve-me".utf8))
  }

  func testCleanupPreservesAReplacementInsertedAtTheDestructiveBoundary() async throws {
    let fixture = try makeFixture()
    let replacement = DescriptorEntryReplacement(targetEntry: nil)
    let executable = try makeExecutable(
      """
      #!/bin/sh
      for argument in "$@"; do target="$argument"; done
      printf partial > "$target/data"
      exit 2
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeDestructiveCloneCleanup: { descriptor, name in
        replacement.replace(parentDescriptor: descriptor, name: name)
      }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "destructive-race"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected cleanup replacement rejection")
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

  func testCleanupPreservesATopLevelReplacementInsertedBeforeRemoval() async throws {
    let fixture = try makeFixture()
    let replacement = DescriptorEntryReplacement(targetEntry: nil)
    let executable = try makeExecutable("#!/bin/sh\nexit 2\n")
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeDestructiveCloneCleanup: { descriptor, name in
        replacement.replace(parentDescriptor: descriptor, name: name)
      }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "top-level-race"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected top-level cleanup replacement rejection")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    let replacementURL = try replacement.replacementURL(in: fixture.root)
    XCTAssertEqual(try Data(contentsOf: replacementURL.appendingPathComponent("keep")), Data("sentinel".utf8))
    try replacement.restoreOriginal(in: fixture.root)
    try await runner.stopRetainedOperation()
    XCTAssertFalse(FileManager.default.fileExists(atPath: replacementURL.path))
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

  #endif

  func testCloneTargetReplacementBetweenCreationAndOpenNeverLaunchesOrDeletesEitherEntry() async throws {
    let fixture = try makeFixture()
    let replacement = DescriptorEntryReplacement(targetEntry: nil)
    let marker = fixture.root.appendingPathComponent("launched")
    let executable = try makeExecutable("#!/bin/sh\ntouch \"\(marker.path)\"\n")
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: executable,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: false,
      beforeCloneTargetOpen: { descriptor, name in
        replacement.replace(parentDescriptor: descriptor, name: name)
      }
    )
    let credentialRequests = CredentialRequestCounter()
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.clone(targetName: "published"), in: fixture.scope) {
        credentialRequests.increment()
        return OperationCredential(copying: source)
      }
      XCTFail("Expected clone staging replacement rejection")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    XCTAssertEqual(credentialRequests.value, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    let replacementURL = try replacement.replacementURL(in: fixture.root)
    XCTAssertEqual(try Data(contentsOf: replacementURL.appendingPathComponent("keep")), Data("sentinel".utf8))
    let originalURL = fixture.root.appendingPathComponent(
      replacementURL.lastPathComponent + "-original",
      isDirectory: true
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
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

  func testGitUsesTheCapturedRepositoryDescriptorAfterFinalValidation() async throws {
    let fixture = try makeFixture()
    let repository = try makeRepository(in: fixture.root)
    let broker = try brokerExecutable()
    let original = fixture.root.appendingPathComponent("captured-original", isDirectory: true)
    let executable = try makeExecutable(
      """
      #!/bin/sh
      printf 'CAPTURED-CONFIG\n'
      while IFS= read -r line; do printf '%s\n' "$line"; done < .git/config
      exit 0
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: broker,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: true,
      afterExecutionAuthorityPrepared: { _ in
        try? FileManager.default.moveItem(at: repository, to: original)
        try? FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false)
        let metadata = repository.appendingPathComponent(".git", isDirectory: true)
        try? FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        try? Data(
          """
          [core]
            repositoryformatversion = 0
            bare = false
          [alias]
            fetch = !echo attacker-config-was-read
          """.utf8
        ).write(to: metadata.appendingPathComponent("config"), options: .atomic)
      }
    )
    let source = SecureSecretBuffer(copying: Data("token".utf8))
    defer { source.clear() }

    let result = try await runner.run(.fetch(repositoryName: "existing"), in: fixture.scope) {
      OperationCredential(copying: source)
    }

    XCTAssertTrue(result.output.contains("CAPTURED-CONFIG"))
    XCTAssertTrue(result.output.contains("url = https://github.com/octo/repo"))
    XCTAssertFalse(result.output.contains("attacker-config-was-read"))
  }

  func testFetchAndPushReceiveTheSameSandboxedGitHubTunnelPolicy() async throws {
    for request in [
      GitRepositoryCapabilityRequest.fetch(repositoryName: "existing"),
      GitRepositoryCapabilityRequest.push(repositoryName: "existing", branch: "main"),
    ] {
      let fixture = try makeFixture()
      _ = try makeRepository(in: fixture.root)
      let broker = try brokerExecutable()
      let executable = try makeExecutable("#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
      let runner = ScopedGitCommandRunner(
        gitExecutableURL: executable,
        brokerExecutableURL: broker,
        operationTimeout: 2,
        wrapsGitInBrokerExecutable: true
      )
      let source = SecureSecretBuffer(copying: Data("token".utf8))
      defer { source.clear() }

      let result = try await runner.run(request, in: fixture.scope) {
        OperationCredential(copying: source)
      }

      XCTAssertTrue(
        result.output.contains("http.proxy="),
        result.output
      )
      XCTAssertTrue(
        result.output.contains("http.http://127.0.0.1:"),
        result.output
      )
      XCTAssertFalse(result.output.contains("--git-dir="))
      XCTAssertFalse(result.output.contains(fixture.root.path))
    }
  }

  func testPostValidationProxyAndCAInjectionCannotReachAnAttackerListener() async throws {
    let fixture = try makeFixture()
    let repository = try makeRealRepository(in: fixture.root)
    let broker = try brokerExecutable()
    let attacker = try LoopbackConnectionProbe()
    defer { attacker.stop() }
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: URL(fileURLWithPath: "/usr/bin/git"),
      brokerExecutableURL: broker,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: true,
      afterExecutionAuthorityPrepared: { _ in
        try? Data(
          """
          [core]
            repositoryformatversion = 0
            bare = false
          [remote "origin"]
            url = https://github.com/octo/repo
            fetch = +refs/heads/*:refs/remotes/origin/*
          [http "https://github.com/octo/repo/info"]
            proxy = http://127.0.0.1:\(attacker.port)
            curloptResolve = +github.com:443:127.0.0.1
            sslCAInfo = /tmp/attacker-ca.pem
            sslVerify = false
          """.utf8
        ).write(to: repository.appendingPathComponent(".git/config"), options: .atomic)
      }
    )
    let source = SecureSecretBuffer(copying: Data("sandbox-token-canary".utf8))
    defer { source.clear() }

    do {
      _ = try await runner.run(.fetch(repositoryName: "existing"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
      XCTFail("Expected the injected endpoint to be unreachable")
    } catch let error as GitCommandRunnerError {
      XCTAssertTrue([.gitFailed, .timedOut].contains(error.failure.category))
      XCTAssertFalse(error.failure.message.contains("sandbox-token-canary"))
    }
    XCTAssertFalse(attacker.wasConnected)
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

  func testInheritedCredentialCapabilityAndDescriptorWritesStayInsideTheSandbox() async throws {
    let fixture = try makeFixture()
    let broker = try brokerExecutable()
    let groupObservation = ProcessGroupObservation()
    let executable = try makeExecutable(
      """
      #!/bin/sh
      set -e
      repository=
      for argument in "$@"; do
        case "$argument" in http://127.0.0.1:*) repository="$argument" ;; esac
      done
      authority=${repository#http://}
      host=${authority%%/*}
      path=${authority#*/}
      printf '%s' "$HOME" > live-home
      request=$(printf 'protocol=http\nhost=%s\npath=%s\n\n' "$host" "$path" | \
        /usr/bin/base64 | /usr/bin/tr -d '\n')
      printf 'get %s\n' "$request" >&3
      IFS=' ' read -r status response <&3
      [ "$status" = OK ]
      credential_output=$(printf '%s' "$response" | /usr/bin/base64 -D)
      case "$credential_output" in *username=x-access-token*) ;; *) exit 92 ;; esac
      touch credential-ready
      while [ ! -e release ]; do sleep 0.01; done
      touch sandbox-write-probe
      if touch "$HOME/../sandbox-escape-$$" 2>/dev/null; then exit 91; fi
      printf 'sandboxed\n'
      """
    )
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: broker,
      operationTimeout: 2,
      wrapsGitInBrokerExecutable: true,
      afterProcessGroupEstablished: { groupObservation.record($0) }
    )
    let source = SecureSecretBuffer(copying: Data("socket-canary-token".utf8))
    defer { source.clear() }

    let operation = Task {
      try await runner.run(.clone(targetName: "helper"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
    }
    let processID = try await groupObservation.waitForProcessID()
    let staging = try await waitForCloneStagingDirectory(in: fixture.root)
    try await waitForFile(staging.appendingPathComponent("credential-ready"))
    let temporaryHome = URL(
      fileURLWithPath: String(
        decoding: try Data(contentsOf: staging.appendingPathComponent("live-home")),
        as: UTF8.self
      )
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryHome.path))
    try assertNoCredentialRepresentations("socket-canary-token", under: fixture.root)
    try assertNoCredentialRepresentations("socket-canary-token", under: temporaryHome)
    let processListing = try processOutput(
      executable: URL(fileURLWithPath: "/bin/ps"),
      arguments: ["eww", "-p", String(processID)]
    )
    XCTAssertFalse(processListing.contains("socket-canary-token"))
    FileManager.default.createFile(
      atPath: staging.appendingPathComponent("release").path,
      contents: Data()
    )
    let result = try await operation.value

    XCTAssertTrue(result.output.contains("sandboxed"))
    XCTAssertFalse(result.output.contains("socket-canary-token"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("helper/sandbox-write-probe").path
      )
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryHome.path))
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
    let groupObservation = ProcessGroupObservation()
    let executable = try makeExecutable(
      """
      #!/bin/sh
      sleep 60 &
      wait $!
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
    let childPIDs = try await waitForChildProcesses(of: observedParentPID, minimumCount: 1)
    XCTAssertTrue(childPIDs.contains { Darwin.getpgid($0) == observedParentPID })

    try await runner.stopRetainedOperation()
    do {
      _ = try await operation.value
      XCTFail("Expected stopped Git operation to fail")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .gitFailed)
    } catch {
      XCTFail("Unexpected stopped operation error: \(error)")
    }

    XCTAssertFalse(processExists(observedParentPID))
    XCTAssertTrue(childPIDs.allSatisfy { !processExists($0) })
  }

  func testFailedProcessGroupStopRetainsRuntimeUntilProductionRetrySucceeds() async throws {
    let fixture = try makeFixture()
    let broker = try brokerExecutable()
    let executable = try makeExecutable(
      """
      #!/bin/sh
      sleep 60 &
      wait $!
      """
    )
    let controller = FailOnceGitProcessGroupController()
    let groupObservation = ProcessGroupObservation()
    let runner = ScopedGitCommandRunner(
      gitExecutableURL: executable,
      brokerExecutableURL: broker,
      operationTimeout: 60,
      stopTimeout: 0.05,
      wrapsGitInBrokerExecutable: true,
      afterProcessGroupEstablished: { groupObservation.record($0) },
      processGroupController: controller.controller
    )
    let source = SecureSecretBuffer(copying: Data("retained-token".utf8))
    defer { source.clear() }
    let operation = Task {
      try await runner.run(.clone(targetName: "retained"), in: fixture.scope) {
        OperationCredential(copying: source)
      }
    }
    let parentPID = try await groupObservation.waitForProcessID()
    let childPIDs = try await waitForChildProcesses(of: parentPID, minimumCount: 1)

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
    XCTAssertTrue(childPIDs.allSatisfy { processExists($0) })

    controller.allowSignals()
    try await runner.stopRetainedOperation()
    do {
      _ = try await operation.value
      XCTFail("Expected stopped operation failure")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .gitFailed)
    }
    XCTAssertFalse(processExists(parentPID))
    XCTAssertTrue(childPIDs.allSatisfy { !processExists($0) })
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

  private func makeRealRepository(in root: URL) throws -> URL {
    let repository = root.appendingPathComponent("existing", isDirectory: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["init", repository.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw GitCommandRunnerError.launchFailed }
    try writeRepositoryConfiguration(
      to: repository.appendingPathComponent(".git/config")
    )
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

  private func waitForCloneStagingDirectory(in root: URL) async throws -> URL {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
      if let name = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .first(where: { $0.hasPrefix(".symphony-clone-") })
      {
        return root.appendingPathComponent(name, isDirectory: true)
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw GitCommandRunnerError.launchFailed
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

  private func waitForChildProcesses(
    of parent: Int32,
    minimumCount: Int
  ) async throws -> [Int32] {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      var pending = [parent]
      var identifiers = Set<Int32>()
      while let ancestor = pending.popLast() {
        let output = try processOutput(
          executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
          arguments: ["-P", String(ancestor)]
        )
        for identifier in output.split(whereSeparator: \.isNewline).compactMap({
          Int32(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        }) where identifiers.insert(identifier).inserted {
          pending.append(identifier)
        }
      }
      if identifiers.count >= minimumCount { return Array(identifiers) }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw GitCommandRunnerError.launchFailed
  }

  private func assertNoCredentialRepresentations(_ token: String, under root: URL) throws {
    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      "Expected credential scan root to exist: \(root.path)"
    )
    XCTAssertTrue(isDirectory.boolValue)
    let data = Data(token.utf8)
    let representations = [
      token,
      data.base64EncodedString(),
      data.map { String(format: "%02x", $0) }.joined(),
      "Bearer \(token)",
      "Basic \(Data("x-access-token:\(token)".utf8).base64EncodedString())",
    ]
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    )
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

private final class LoopbackConnectionProbe: @unchecked Sendable {
  let port: UInt16
  private let descriptor: Int32
  private let lock = NSLock()
  private var stopped = false
  private var connected = false

  init() throws {
    let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw GitCommandRunnerError.launchFailed }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, Darwin.listen(listener, 1) == 0 else {
      Darwin.close(listener)
      throw GitCommandRunnerError.launchFailed
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.getsockname(listener, $0, &length)
      }
    }
    guard named == 0 else {
      Darwin.close(listener)
      throw GitCommandRunnerError.launchFailed
    }
    descriptor = listener
    port = UInt16(bigEndian: actual.sin_port)
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let client = Darwin.accept(descriptor, nil, nil)
      if client >= 0 {
        lock.withLock { connected = true }
        Darwin.close(client)
      }
    }
  }

  deinit { stop() }
  var wasConnected: Bool { lock.withLock { connected } }

  func stop() {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      Darwin.shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
    }
  }
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

private final class LateHardLinkInsertion: @unchecked Sendable {
  private let lock = NSLock()
  private let destination: URL
  private var inserted = false

  init(destination: URL) {
    self.destination = destination
  }

  func insert(from descriptor: Int32, name: String) {
    lock.withLock {
      guard !inserted else { return }
      guard Darwin.linkat(descriptor, name, AT_FDCWD, destination.path, 0) == 0 else { return }
      inserted = true
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
