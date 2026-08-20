import Darwin
import Foundation
import XCTest

@testable import SymphonyCredentialBrokerProtocol
@testable import SymphonyDesktopInfrastructure

final class CredentialBrokerProcessLauncherTests: XCTestCase {
  func testSessionUsesOnlyNamespaceIdentityAndSanitizedEnvironment() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let argsURL = directory.appendingPathComponent("args")
    let environmentURL = directory.appendingPathComponent("environment")
    let stoppedURL = directory.appendingPathComponent("stopped")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > "$BROKER_TEST_ARGS_FILE"
        env > "$BROKER_TEST_ENV_FILE"
        printf '{"status":"unlocked"}\\n'
        read command
        printf '%s' "$command" > "$BROKER_TEST_STOPPED_FILE"
        """
    )
    let namespaceID = UUID()
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 1,
      stopTimeout: 1,
      environment: [
        "PATH": "/usr/bin:/bin",
        "BROKER_TEST_ARGS_FILE": argsURL.path,
        "BROKER_TEST_ENV_FILE": environmentURL.path,
        "BROKER_TEST_STOPPED_FILE": stoppedURL.path,
        "GITHUB_APP_PRIVATE_KEY": "private-key-material",
        "GITHUB_TOKEN": "installation-token",
        "GH_TOKEN": "cli-token",
        "OPENAI_API_KEY": "openai-key",
      ]
    )

    let session = try await launcher.unlock(namespaceID: namespaceID)

    let arguments = try String(contentsOf: argsURL, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
    XCTAssertEqual(arguments, ["serve", namespaceID.uuidString.lowercased()])
    let environment = try String(contentsOf: environmentURL, encoding: .utf8)
    XCTAssertFalse(environment.contains("private-key-material"))
    XCTAssertFalse(environment.contains("installation-token"))
    XCTAssertFalse(environment.contains("cli-token"))
    XCTAssertFalse(environment.contains("openai-key"))

    try await session.lock()

    let stoppedCommand = try JSONDecoder().decode(
      CredentialBrokerCommand.self,
      from: Data(contentsOf: stoppedURL)
    )
    XCTAssertEqual(stoppedCommand, .lock)
  }

  func testUnlockDenialIsReturnedWithoutCreatingASession() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"failed","message":"Authentication cancelled."}\\n'
        """
    )
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 1,
      stopTimeout: 1,
      environment: ["PATH": "/usr/bin:/bin"]
    )

    do {
      _ = try await launcher.unlock(namespaceID: UUID())
      XCTFail("Expected unlock to be denied")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Authentication cancelled.")
    }
  }

  func testMissingExecutableProducesActionableError() async {
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: nil,
      environment: [:]
    )

    do {
      _ = try await launcher.unlock(namespaceID: UUID())
      XCTFail("Expected missing executable error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("could not be found"))
    }
  }

  func testFailedForceKillRetainsRuntimeBlocksReplacementAndSupportsRetry() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\\n'
        trap '' TERM
        read command
        exec /usr/bin/tail -f /dev/null
        """
    )
    let forceKill = RetryingForceKill()
    let namespaceID = UUID()
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 1,
      stopTimeout: 0.05,
      environment: ["PATH": "/usr/bin:/bin"],
      forceKill: { processID in forceKill.call(processID) }
    )
    let session = try await launcher.unlock(namespaceID: namespaceID)

    do {
      try await session.lock()
      XCTFail("Expected the first forced stop to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("could not be stopped safely"))
    }

    do {
      _ = try await launcher.unlock(namespaceID: namespaceID)
      XCTFail("Expected retained runtime to block replacement")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("already owned"))
    }

    forceKill.allowTermination()
    try await launcher.stop(namespaceID: namespaceID)
    let replacement = try await launcher.unlock(namespaceID: namespaceID)
    try await replacement.lock()
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("CredentialBrokerProcessLauncherTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func executableScript(in directory: URL, contents: String) throws -> URL {
    let url = directory.appendingPathComponent("broker-fixture")
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
}

private final class RetryingForceKill: @unchecked Sendable {
  private let lock = NSLock()
  private var isAllowed = false

  func allowTermination() {
    lock.withLock { isAllowed = true }
  }

  func call(_ processID: Int32) -> Int32 {
    lock.withLock {
      isAllowed ? Darwin.kill(processID, SIGKILL) : -1
    }
  }
}
