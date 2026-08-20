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

  private func makeExecutable(_ source: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-fake-git-\(UUID().uuidString)")
    try Data(source.utf8).write(to: url)
    XCTAssertEqual(chmod(url.path, 0o700), 0)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
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
