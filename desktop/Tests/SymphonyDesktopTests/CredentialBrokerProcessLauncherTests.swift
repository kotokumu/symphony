import Foundation
import XCTest

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

    XCTAssertEqual(try String(contentsOf: stoppedURL, encoding: .utf8), "lock")
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
