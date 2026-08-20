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

  func testHandshakeTimeoutCleansUpRuntimeAndAllowsReplacement() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstAttemptURL = directory.appendingPathComponent("first-attempt")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        if [ ! -e "$BROKER_FIRST_ATTEMPT_FILE" ]; then
          : > "$BROKER_FIRST_ATTEMPT_FILE"
          exec /usr/bin/tail -f /dev/null
        fi
        printf '{"status":"unlocked"}\n'
        IFS= read -r lock_command
        """
    )
    let namespaceID = UUID()
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 0.05,
      stopTimeout: 0.1,
      environment: [
        "PATH": "/usr/bin:/bin",
        "BROKER_FIRST_ATTEMPT_FILE": firstAttemptURL.path,
      ]
    )
    let clock = ContinuousClock()
    let started = clock.now

    do {
      _ = try await launcher.unlock(namespaceID: namespaceID)
      XCTFail("Expected handshake timeout")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("unlock timed out"))
    }
    XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))

    let replacement = try await launcher.unlock(namespaceID: namespaceID)
    try await replacement.lock()
  }

  func testCapabilityTimeoutCleansUpRuntimeAndAllowsReplacement() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstCapabilityURL = directory.appendingPathComponent("first-capability")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\n'
        IFS= read -r command
        if [ ! -e "$BROKER_FIRST_CAPABILITY_FILE" ]; then
          : > "$BROKER_FIRST_CAPABILITY_FILE"
          exec /usr/bin/tail -f /dev/null
        fi
        printf '{"status":"signature","payload":"AQ=="}\n'
        IFS= read -r lock_command
        """
    )
    let namespaceID = UUID()
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 0.2,
      capabilityTimeout: 0.05,
      stopTimeout: 0.1,
      environment: [
        "PATH": "/usr/bin:/bin",
        "BROKER_FIRST_CAPABILITY_FILE": firstCapabilityURL.path,
      ]
    )
    let session = try await launcher.unlock(namespaceID: namespaceID)
    let clock = ContinuousClock()
    let started = clock.now

    do {
      _ = try await session.signChallenge(Data([1]))
      XCTFail("Expected capability timeout")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("operation timed out"))
    }
    XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))

    let replacement = try await launcher.unlock(namespaceID: namespaceID)
    let signature = try await replacement.signChallenge(Data([1]))
    XCTAssertEqual(signature, Data([1]))
    try await replacement.lock()
  }

  func testClosedBrokerInputReturnsAnErrorWithoutTerminatingDesktopProcess() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputClosedURL = directory.appendingPathComponent("input-closed")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\\n'
        exec 0<&-
        : > "$BROKER_INPUT_CLOSED_FILE"
        sleep 1
        """
    )
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 1,
      stopTimeout: 0.1,
      environment: [
        "PATH": "/usr/bin:/bin",
        "BROKER_INPUT_CLOSED_FILE": inputClosedURL.path,
      ]
    )
    let session = try await launcher.unlock(namespaceID: UUID())
    await eventually { FileManager.default.fileExists(atPath: inputClosedURL.path) }

    do {
      _ = try await session.signChallenge(Data([1]))
      XCTFail("Expected writing to the closed broker pipe to fail")
    } catch {
      XCTAssertFalse(error.localizedDescription.isEmpty)
    }
  }

  func testGitHubCapabilitiesUseFramedRequestsAndReturnOnlyDescriptors() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configureURL = directory.appendingPathComponent("configure-command")
    let installationsURL = directory.appendingPathComponent("installations-command")
    let repositoriesURL = directory.appendingPathComponent("repositories-command")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\n'
        IFS= read -r configure
        printf '%s' "$configure" > "$BROKER_CONFIGURE_FILE"
        printf '{"status":"githubAppConfigured"}\n'
        IFS= read -r installations
        printf '%s' "$installations" > "$BROKER_INSTALLATIONS_FILE"
        printf '{"status":"githubInstallations","installations":[{"id":20,"accountLogin":"octo","accountType":"Organization","permissions":{"issues":"read","contents":"write"},"isSuspended":false}]}\n'
        IFS= read -r repositories
        printf '%s' "$repositories" > "$BROKER_REPOSITORIES_FILE"
        printf '{"status":"githubRepositories","repositories":[{"id":30,"fullName":"octo/research","htmlURL":"https://github.com/octo/research","isPrivate":true}]}\n'
        IFS= read -r lock_command
        """
    )
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 1,
      stopTimeout: 1,
      environment: [
        "PATH": "/usr/bin:/bin",
        "BROKER_CONFIGURE_FILE": configureURL.path,
        "BROKER_INSTALLATIONS_FILE": installationsURL.path,
        "BROKER_REPOSITORIES_FILE": repositoriesURL.path,
      ]
    )
    let session = try await launcher.unlock(namespaceID: UUID())
    let keyURL = URL(fileURLWithPath: "/private/github-app.pem")

    try await session.configureGitHubApp(appID: 10, privateKeyFileURL: keyURL)
    let installations = try await session.listGitHubInstallations()
    let repositories = try await session.listGitHubRepositories(installationID: 20)

    let configure = try JSONDecoder().decode(
      CredentialBrokerCommand.self,
      from: Data(contentsOf: configureURL)
    )
    XCTAssertEqual(configure, .configureGitHubApp(appID: 10, privateKeyFilePath: keyURL.path))
    let installationCommand = try JSONDecoder().decode(
      CredentialBrokerCommand.self,
      from: Data(contentsOf: installationsURL)
    )
    let repositoryCommand = try JSONDecoder().decode(
      CredentialBrokerCommand.self,
      from: Data(contentsOf: repositoriesURL)
    )
    XCTAssertEqual(installationCommand, .listGitHubInstallations)
    XCTAssertEqual(repositoryCommand, .listGitHubRepositories(installationID: 20))
    XCTAssertEqual(installations.first?.accountLogin, "octo")
    XCTAssertEqual(repositories.first?.fullName, "octo/research")
    try await session.lock()
  }

  func testScopedRepositoryCapabilitiesUseClosedBrokerFrames() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let authorizationURL = directory.appendingPathComponent("authorization")
    let issueURL = directory.appendingPathComponent("issue")
    let gitURL = directory.appendingPathComponent("git")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\n'
        IFS= read -r authorization
        printf '%s' "$authorization" > "$BROKER_AUTHORIZATION_FILE"
        printf '{"status":"githubRepositoryAuthorized"}\n'
        IFS= read -r issue
        printf '%s' "$issue" > "$BROKER_ISSUE_FILE"
        printf '{"status":"githubIssueResponse","githubIssueResponse":{"kind":"issue","issue":{"number":7,"labels":[],"assigneeLogins":[]}}}\n'
        IFS= read -r git
        printf '%s' "$git" > "$BROKER_GIT_FILE"
        printf '{"status":"githubGitResult","githubGitResult":{"exitStatus":0,"output":"ok","wasTruncated":false}}\n'
        IFS= read -r lock_command
        """
    )
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 1,
      stopTimeout: 1,
      environment: [
        "PATH": "/usr/bin:/bin",
        "BROKER_AUTHORIZATION_FILE": authorizationURL.path,
        "BROKER_ISSUE_FILE": issueURL.path,
        "BROKER_GIT_FILE": gitURL.path,
      ]
    )
    let session = try await launcher.unlock(namespaceID: UUID())
    let authorization = GitHubRepositoryAuthorization(
      appID: 10,
      installationID: 20,
      repositoryID: 30,
      repositoryFullName: "octo/repo",
      repositoryURL: URL(string: "https://github.com/octo/repo")!,
      workspacesRoot: URL(fileURLWithPath: "/private/workspaces")
    )

    try await session.authorizeGitHubRepository(authorization)
    let issue = try await session.performGitHubIssueRequest(.getIssue(issueNumber: 7))
    let git = try await session.performGitHubGitOperation(.clone(targetName: "issue-7"))

    XCTAssertEqual(issue, .issue(GitHubIssueRecord(number: 7)))
    XCTAssertEqual(git.output, "ok")
    XCTAssertEqual(
      try JSONDecoder().decode(CredentialBrokerCommand.self, from: Data(contentsOf: authorizationURL)),
      .authorizeGitHubRepository(authorization)
    )
    XCTAssertEqual(
      try JSONDecoder().decode(CredentialBrokerCommand.self, from: Data(contentsOf: issueURL)),
      .performGitHubIssueRequest(.getIssue(issueNumber: 7))
    )
    XCTAssertEqual(
      try JSONDecoder().decode(CredentialBrokerCommand.self, from: Data(contentsOf: gitURL)),
      .performGitHubGitOperation(.clone(targetName: "issue-7"))
    )
    try await session.lock()
  }

  func testGitHubCapabilityRejectsFailedWrongAndMalformedFrames() async throws {
    let responses = [
      ("{\"status\":\"failed\",\"message\":\"Installation revoked.\"}", "Installation revoked."),
      ("{\"status\":\"githubRepositories\",\"repositories\":[]}", "invalid capability response"),
      ("not-json", "invalid capability response"),
    ]
    for (response, expected) in responses {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let script = try executableScript(
        in: directory,
        contents: """
          #!/bin/sh
          printf '{"status":"unlocked"}\n'
          IFS= read -r command
          printf '%s\n' '\(response)'
          """
      )
      let launcher = CredentialBrokerProcessLauncher(
        executableURL: script,
        handshakeTimeout: 1,
        stopTimeout: 1,
        environment: ["PATH": "/usr/bin:/bin"]
      )
      let session = try await launcher.unlock(namespaceID: UUID())

      do {
        _ = try await session.listGitHubInstallations()
        XCTFail("Expected broker frame rejection")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
      }
    }
  }

  func testGitHubCapabilityRejectsOversizedFrame() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\n'
        IFS= read -r command
        /usr/bin/perl -e 'print "a" x 1048577, "\n"'
        """
    )
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 10,
      stopTimeout: 1,
      environment: ["PATH": "/usr/bin:/bin"]
    )
    let session = try await launcher.unlock(namespaceID: UUID())

    do {
      _ = try await session.listGitHubInstallations()
      XCTFail("Expected broker frame limit")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("safe limit"), error.localizedDescription)
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
    let firstReceivedURL = directory.appendingPathComponent("first-received")
    let secondReceivedURL = directory.appendingPathComponent("second-received")
    let releaseFirstURL = directory.appendingPathComponent("release-first")
    let releaseSecondURL = directory.appendingPathComponent("release-second")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\\n'
        IFS= read -r first
        printf '%s' "$first" > "$BROKER_FIRST_RECEIVED_FILE"
        exec 3<&0
        (
          IFS= read -r second <&3
          printf '%s' "$second" > "$BROKER_SECOND_RECEIVED_FILE"
          while [ ! -e "$BROKER_RELEASE_SECOND_FILE" ]; do sleep 0.01; done
          printf '{"status":"signature","payload":"Ag=="}\\n'
        ) &
        while [ ! -e "$BROKER_RELEASE_FIRST_FILE" ]; do sleep 0.01; done
        printf '{"status":"signature","payload":"AQ=="}\\n'
        wait
        IFS= read -r lock_command
        """
    )
    let namespaceID = UUID()
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 1,
      stopTimeout: 1,
      environment: [
        "PATH": "/usr/bin:/bin",
        "BROKER_FIRST_RECEIVED_FILE": firstReceivedURL.path,
        "BROKER_SECOND_RECEIVED_FILE": secondReceivedURL.path,
        "BROKER_RELEASE_FIRST_FILE": releaseFirstURL.path,
        "BROKER_RELEASE_SECOND_FILE": releaseSecondURL.path,
      ]
    )
    let session = try await launcher.unlock(namespaceID: namespaceID)

    let first = Task { try await session.signChallenge(Data([1])) }
    await eventually { FileManager.default.fileExists(atPath: firstReceivedURL.path) }
    let second = Task { try await session.signChallenge(Data([2])) }
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondReceivedURL.path))

    try Data().write(to: releaseFirstURL)
    let firstResult = try await first.value
    XCTAssertEqual(firstResult, Data([1]))
    await eventually { FileManager.default.fileExists(atPath: secondReceivedURL.path) }
    try Data().write(to: releaseSecondURL)
    let secondResult = try await second.value
    XCTAssertEqual(secondResult, Data([2]))
    try await session.lock()
  }

  func testLockPreemptsANeverRespondingCapabilityWithinStopDeadline() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let requestStartedURL = directory.appendingPathComponent("request-started")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\\n'
        IFS= read -r command
        : > "$BROKER_REQUEST_STARTED_FILE"
        exec /usr/bin/tail -f /dev/null
        """
    )
    let namespaceID = UUID()
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 60,
      capabilityTimeout: 2,
      stopTimeout: 0.1,
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
    let clock = ContinuousClock()
    let started = clock.now
    try await session.lock()
    let elapsed = started.duration(to: clock.now)

    XCTAssertLessThan(elapsed, .seconds(1))
    do {
      _ = try await capability.value
      XCTFail("Expected the interrupted capability to fail")
    } catch {}
  }

  func testCancelledQueuedCapabilityIsNeverSentBeforeLock() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstReceivedURL = directory.appendingPathComponent("first-received")
    let secondReceivedURL = directory.appendingPathComponent("second-received")
    let script = try executableScript(
      in: directory,
      contents: """
        #!/bin/sh
        printf '{"status":"unlocked"}\\n'
        IFS= read -r first
        : > "$BROKER_FIRST_RECEIVED_FILE"
        exec 3<&0
        (
          IFS= read -r second <&3
          case "$second" in
            *'Ag=='*) : > "$BROKER_SECOND_RECEIVED_FILE" ;;
          esac
        ) &
        exec /usr/bin/tail -f /dev/null
        """
    )
    let namespaceID = UUID()
    let commandGate = NamespaceCommandGate()
    let launcher = CredentialBrokerProcessLauncher(
      executableURL: script,
      handshakeTimeout: 60,
      capabilityTimeout: 2,
      stopTimeout: 0.1,
      environment: [
        "PATH": "/usr/bin:/bin",
        "BROKER_FIRST_RECEIVED_FILE": firstReceivedURL.path,
        "BROKER_SECOND_RECEIVED_FILE": secondReceivedURL.path,
      ],
      forceKill: { Darwin.kill($0, SIGKILL) },
      commandGate: commandGate
    )
    let session = try await launcher.unlock(namespaceID: namespaceID)
    let first = Task { try await session.signChallenge(Data([1])) }
    await eventually { FileManager.default.fileExists(atPath: firstReceivedURL.path) }
    let second = Task { try await session.signChallenge(Data([2])) }
    let secondIsQueued = await commandGate.waitUntilQueued(
      namespaceID,
      timeout: .seconds(1)
    )
    XCTAssertTrue(secondIsQueued)
    second.cancel()

    try await session.lock()

    do {
      _ = try await second.value
      XCTFail("Expected queued capability cancellation")
    } catch is CancellationError {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondReceivedURL.path))
    first.cancel()
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
