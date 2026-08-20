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

  func testConcurrentCapabilitiesKeepEachResponseBoundToItsRequest() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\\n'
        while IFS= read -r command; do
          case "$command" in
            *'"operation":"lock"'*) exit 0 ;;
            *'AQ=='*) sleep 0.1; printf '{"status":"signature","payload":"AQ=="}\\n' ;;
            *'Ag=='*) printf '{"status":"signature","payload":"Ag=="}\\n' ;;
            *) exit 2 ;;
          esac
        done
        """
    )
    let namespaceID = UUID()
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 1,
      stopTimeout: 1,
      environment: ["PATH": "/usr/bin:/bin"]
    )
    let session = try await launcher.unlock(namespaceID: namespaceID)

    async let first = session.signChallenge(Data([1]))
    async let second = session.signChallenge(Data([2]))
    let results = try await (first, second)

    XCTAssertEqual(results.0, Data([1]))
    XCTAssertEqual(results.1, Data([2]))
    try await session.lock()
  }

  func testLockWaitsForInFlightCapabilityBeforeCompleting() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let requestStartedURL = directory.appendingPathComponent("request-started")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\\n'
        while IFS= read -r command; do
          case "$command" in
            *'"operation":"lock"'*) exit 0 ;;
            *)
              : > "$BROKER_REQUEST_STARTED_FILE"
              sleep 0.15
              printf '{"status":"signature","payload":"AQ=="}\\n'
              ;;
          esac
        done
        """
    )
    let namespaceID = UUID()
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 1,
      stopTimeout: 1,
      environment: [
        "PATH": "/usr/bin:/bin",
        "BROKER_REQUEST_STARTED_FILE": requestStartedURL.path,
      ]
    )
    let session = try await launcher.unlock(namespaceID: namespaceID)
    let capability = Task {
      try await session.signChallenge(Data([1]))
    }
    await eventually { FileManager.default.fileExists(atPath: requestStartedURL.path) }
    let lockFinished = LockedFlag()
    let lock = Task {
      try await session.lock()
      await lockFinished.mark()
    }
    try await Task.sleep(for: .milliseconds(30))
    let finishedEarly = await lockFinished.value
    XCTAssertFalse(finishedEarly)

    let capabilityResult = try await capability.value
    XCTAssertEqual(capabilityResult, Data([1]))
    try await lock.value
    let finished = await lockFinished.value
    XCTAssertTrue(finished)
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

  private func eventually(
    _ condition: @escaping () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not satisfied", file: file, line: line)
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

private actor LockedFlag {
  private(set) var value = false

  func mark() {
    value = true
  }
}
