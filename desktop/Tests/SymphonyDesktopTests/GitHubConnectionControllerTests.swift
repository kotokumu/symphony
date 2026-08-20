import Foundation
import XCTest

@testable import SymphonyCredentialBrokerProtocol
@testable import SymphonyDesktop
@testable import SymphonyDesktopCore

@MainActor
final class GitHubConnectionControllerTests: XCTestCase {
  func testInvalidAppIDsHaveNoCredentialOrLedgerSideEffects() async {
    let invalidValues = ["", "abc", "0", "-1", "9223372036854775808"]
    for value in invalidValues {
      let namespaceID = UUID()
      let broker = RecordingGitHubConnectionBroker()
      let cleanup = RecordingGitHubCredentialCleanup()
      let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)

      await controller.beginConnection(
        namespaceID: namespaceID,
        appIDText: value,
        privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
      )

      guard case .failed(let message) = controller.state(for: namespaceID) else {
        return XCTFail("Expected invalid App ID failure for \(value)")
      }
      XCTAssertTrue(message.contains("numeric GitHub App ID"))
      let configured = await broker.configured
      let started = await cleanup.started
      XCTAssertTrue(configured.isEmpty)
      XCTAssertTrue(started.isEmpty)
    }
  }

  func testConnectsOneNamespaceThroughInstallationAndRepositorySelection() async throws {
    let namespaceID = UUID()
    let broker = RecordingGitHubConnectionBroker()
    let controller = GitHubConnectionController(
      broker: broker,
      credentialCleanup: RecordingGitHubCredentialCleanup()
    )
    let keyURL = URL(fileURLWithPath: "/private/github-app.pem")

    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: keyURL
    )
    guard case .choosingInstallation(let appID, let installations) = controller.state(
      for: namespaceID
    ) else {
      return XCTFail("Expected installation selection")
    }
    XCTAssertEqual(appID, 10)

    await controller.chooseInstallation(try XCTUnwrap(installations.first), namespaceID: namespaceID)
    guard case .choosingRepository(_, _, let repositories) = controller.state(for: namespaceID)
    else {
      return XCTFail("Expected repository selection")
    }
    var saved: GitHubConnection?
    try await controller.connect(
      try XCTUnwrap(repositories.first),
      namespaceID: namespaceID,
      save: { saved = $0 }
    )

    XCTAssertEqual(saved?.repositoryFullName, "octo/research")
    XCTAssertEqual(controller.state(for: namespaceID), .idle)
    let configured = await broker.configured
    XCTAssertEqual(configured, [Configuration(namespaceID: namespaceID, appID: 10, keyURL: keyURL)])
  }

  func testMissingPermissionsAreActionableBeforeRepositoryTokenCreation() async throws {
    let namespaceID = UUID()
    let broker = RecordingGitHubConnectionBroker(
      installations: [
        GitHubInstallation(
          id: 20,
          accountLogin: "octo",
          accountType: "Organization",
          permissions: ["contents": "read"],
          isSuspended: false
        )
      ]
    )
    let controller = GitHubConnectionController(
      broker: broker,
      credentialCleanup: RecordingGitHubCredentialCleanup()
    )
    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )
    guard case .choosingInstallation(_, let installations) = controller.state(for: namespaceID)
    else { return XCTFail("Expected installations") }

    await controller.chooseInstallation(try XCTUnwrap(installations.first), namespaceID: namespaceID)

    guard case .failed(let message) = controller.state(for: namespaceID) else {
      return XCTFail("Expected permission failure")
    }
    XCTAssertTrue(message.contains("Issues: Read and write"))
    XCTAssertTrue(message.contains("Contents: Read and write"))
    let repositoryRequestCount = await broker.repositoryRequestCount
    XCTAssertEqual(repositoryRequestCount, 0)
  }

  func testOneNamespaceSetupDoesNotChangeAnotherNamespaceState() async {
    let first = UUID()
    let second = UUID()
    let controller = GitHubConnectionController(
      broker: RecordingGitHubConnectionBroker(),
      credentialCleanup: RecordingGitHubCredentialCleanup()
    )

    await controller.beginConnection(
      namespaceID: first,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )

    guard case .choosingInstallation = controller.state(for: first) else {
      return XCTFail("Expected first namespace setup")
    }
    XCTAssertEqual(controller.state(for: second), .idle)
  }

  func testSaveFailurePurgesConfiguredCredentialBeforeRetry() async throws {
    let namespaceID = UUID()
    let broker = RecordingGitHubConnectionBroker()
    let cleanup = RecordingGitHubCredentialCleanup()
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)
    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )
    guard case .choosingInstallation(_, let installations) = controller.state(for: namespaceID)
    else { return XCTFail("Expected installations") }
    await controller.chooseInstallation(try XCTUnwrap(installations.first), namespaceID: namespaceID)
    guard case .choosingRepository(_, _, let repositories) = controller.state(for: namespaceID)
    else { return XCTFail("Expected repositories") }

    do {
      try await controller.connect(
        try XCTUnwrap(repositories.first),
        namespaceID: namespaceID,
        save: { _ in throw TestGitHubConnectionError.saveFailed }
      )
      XCTFail("Expected save failure")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Connection save failed.")
    }
    let purged = await cleanup.cleaned
    XCTAssertEqual(purged, [namespaceID])
  }

  func testCheckReportsRevokedInstallationAndDisconnectPersistsBeforePurge() async throws {
    let namespaceID = UUID()
    let operations = MainActorOperationRecorder()
    let broker = RecordingGitHubConnectionBroker(installations: [])
    let cleanup = RecordingGitHubCredentialCleanup(operations: operations)
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)
    let connection = try GitHubConnection(
      appID: 10,
      installationID: 20,
      accountLogin: "octo",
      repositoryID: 30,
      repositoryFullName: "octo/research",
      repositoryURL: URL(string: "https://github.com/octo/research")!
    )

    await controller.check(connection, namespaceID: namespaceID)
    guard case .failed(let message) = controller.state(for: namespaceID) else {
      return XCTFail("Expected revoked installation")
    }
    XCTAssertTrue(message.contains("no longer accessible"))

    _ = try await controller.disconnect(namespaceID: namespaceID) {
      operations.append("save-disconnected")
    }
    XCTAssertEqual(operations.values.suffix(3), ["stage", "save-disconnected", "purge"])
  }

  func testCancelWaitsForDiscoveryAndDoesNotPublishItsStaleResult() async throws {
    let namespaceID = UUID()
    let events = LifecycleEventRecorder()
    let broker = GatedGitHubConnectionBroker(events: events)
    let cleanup = RecordingGitHubCredentialCleanup(events: events)
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)
    let begin = Task {
      await controller.beginConnection(
        namespaceID: namespaceID,
        appIDText: "10",
        privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
      )
    }
    await broker.waitUntilInstallationDiscoveryStarts()

    let cancel = Task { await controller.cancelSetup(namespaceID: namespaceID) }
    await broker.finishInstallationDiscovery()
    _ = await begin.value
    let cancellationWarning = await cancel.value
    XCTAssertNil(cancellationWarning)
    XCTAssertEqual(controller.state(for: namespaceID), .idle)
    let cleaned = await cleanup.cleaned
    let recordedEvents = await events.values
    XCTAssertEqual(cleaned, [namespaceID])
    XCTAssertEqual(
      recordedEvents,
      ["configuration-finished", "installations-started", "installations-finished", "cleanup"]
    )

    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "11",
      privateKeyFileURL: URL(fileURLWithPath: "/private/replacement.pem")
    )
    guard case .choosingInstallation(let appID, _) = controller.state(for: namespaceID) else {
      return XCTFail("Expected a replacement setup")
    }
    XCTAssertEqual(appID, 11)
  }

  func testCancelWaitsForPrivateKeyConfigurationBeforePurging() async {
    let namespaceID = UUID()
    let events = LifecycleEventRecorder()
    let broker = GatedGitHubConnectionBroker(gatePoint: .configuration, events: events)
    let cleanup = RecordingGitHubCredentialCleanup(events: events)
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)
    let begin = Task {
      await controller.beginConnection(
        namespaceID: namespaceID,
        appIDText: "10",
        privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
      )
    }
    await broker.waitUntilGateStarts()

    let cancel = Task { await controller.cancelSetup(namespaceID: namespaceID) }
    await broker.finishGate()
    _ = await begin.value
    _ = await cancel.value

    let cleaned = await cleanup.cleaned
    let recordedEvents = await events.values
    XCTAssertEqual(cleaned, [namespaceID])
    XCTAssertEqual(
      recordedEvents,
      ["configuration-started", "configuration-finished", "installations-finished", "cleanup"]
    )
    XCTAssertEqual(controller.state(for: namespaceID), .idle)
  }

  func testConcurrentCancelCallsShareOneJoinAndOneCleanup() async {
    let namespaceID = UUID()
    let events = LifecycleEventRecorder()
    let broker = GatedGitHubConnectionBroker(gatePoint: .configuration, events: events)
    let cleanup = RecordingGitHubCredentialCleanup(events: events)
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)
    let begin = Task {
      await controller.beginConnection(
        namespaceID: namespaceID,
        appIDText: "10",
        privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
      )
    }
    await broker.waitUntilGateStarts()
    let firstCancel = Task { await controller.cancelSetup(namespaceID: namespaceID) }
    let secondCancel = Task { await controller.cancelSetup(namespaceID: namespaceID) }

    await broker.finishGate()
    _ = await begin.value
    let firstWarning = await firstCancel.value
    let secondWarning = await secondCancel.value
    XCTAssertNil(firstWarning)
    XCTAssertNil(secondWarning)

    let cleaned = await cleanup.cleaned
    let recordedEvents = await events.values
    XCTAssertEqual(cleaned, [namespaceID])
    XCTAssertEqual(
      recordedEvents,
      ["configuration-started", "configuration-finished", "installations-finished", "cleanup"]
    )
  }

  func testCancelWaitsForRepositoryDiscoveryAndRejectsStaleSelection() async throws {
    let namespaceID = UUID()
    let broker = GatedGitHubConnectionBroker(gatePoint: .repositories)
    let cleanup = RecordingGitHubCredentialCleanup()
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)
    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )
    guard case .choosingInstallation(_, let installations) = controller.state(for: namespaceID)
    else { return XCTFail("Expected installation selection") }
    let choose = Task {
      await controller.chooseInstallation(installations[0], namespaceID: namespaceID)
    }
    await broker.waitUntilGateStarts()

    let cancel = Task { await controller.cancelSetup(namespaceID: namespaceID) }
    await broker.finishGate()
    _ = await choose.value
    _ = await cancel.value

    XCTAssertEqual(controller.state(for: namespaceID), .idle)
    let cleaned = await cleanup.cleaned
    XCTAssertEqual(cleaned, [namespaceID])
  }

  func testOverlappingSetupIsRejectedWithoutReplacingTheOwnedCredential() async {
    let namespaceID = UUID()
    let broker = GatedGitHubConnectionBroker(gatePoint: .installations)
    let controller = GitHubConnectionController(
      broker: broker,
      credentialCleanup: RecordingGitHubCredentialCleanup()
    )
    let first = Task {
      await controller.beginConnection(
        namespaceID: namespaceID,
        appIDText: "10",
        privateKeyFileURL: URL(fileURLWithPath: "/private/first.pem")
      )
    }
    await broker.waitUntilGateStarts()

    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "11",
      privateKeyFileURL: URL(fileURLWithPath: "/private/second.pem")
    )

    let configured = await broker.configured
    XCTAssertEqual(configured.map(\.appID), [10])
    await broker.finishGate()
    _ = await first.value
  }

  func testCheckCannotEnterWhileDisconnectOwnsTheNamespace() async throws {
    let namespaceID = UUID()
    let gate = AsyncGate()
    let controller = GitHubConnectionController(
      broker: RecordingGitHubConnectionBroker(),
      credentialCleanup: RecordingGitHubCredentialCleanup()
    )
    let connection = try makeConnection()
    let disconnect = Task {
      try await controller.disconnect(namespaceID: namespaceID) {
        await gate.wait()
      }
    }
    await gate.waitUntilEntered()

    await controller.check(connection, namespaceID: namespaceID)
    XCTAssertEqual(controller.state(for: namespaceID), .saving)

    await gate.open()
    let warning = try await disconnect.value
    XCTAssertNil(warning)
    XCTAssertEqual(controller.state(for: namespaceID), .idle)
  }

  func testQuiesceCancelsDiscoveryBeforeWindowCredentialLocking() async throws {
    let namespaceID = UUID()
    let broker = GatedGitHubConnectionBroker(gatePoint: .installations)
    let cleanup = RecordingGitHubCredentialCleanup()
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)
    let begin = Task {
      await controller.beginConnection(
        namespaceID: namespaceID,
        appIDText: "10",
        privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
      )
    }
    await broker.waitUntilGateStarts()
    let quiesce = Task { try await controller.quiesceAll() }

    await broker.finishGate()
    _ = await begin.value
    try await quiesce.value

    XCTAssertEqual(controller.state(for: namespaceID), .idle)
    let cleaned = await cleanup.cleaned
    XCTAssertEqual(cleaned, [namespaceID])
  }

  func testQuiescenceClosesAdmissionUntilExplicitResume() async throws {
    let first = UUID()
    let second = UUID()
    let broker = GatedGitHubConnectionBroker(gatePoint: .installations)
    let controller = GitHubConnectionController(
      broker: broker,
      credentialCleanup: RecordingGitHubCredentialCleanup()
    )
    let begin = Task {
      await controller.beginConnection(
        namespaceID: first,
        appIDText: "10",
        privateKeyFileURL: URL(fileURLWithPath: "/private/first.pem")
      )
    }
    await broker.waitUntilGateStarts()
    let quiesce = Task { try await controller.quiesceAll() }
    while !controller.isAdmissionSuspended { await Task.yield() }

    await controller.beginConnection(
      namespaceID: second,
      appIDText: "11",
      privateKeyFileURL: URL(fileURLWithPath: "/private/second.pem")
    )
    XCTAssertEqual(controller.state(for: second), .idle)
    await broker.finishGate()
    _ = await begin.value
    try await quiesce.value

    controller.resumeAfterSecurityOperation()
    await controller.beginConnection(
      namespaceID: second,
      appIDText: "11",
      privateKeyFileURL: URL(fileURLWithPath: "/private/second.pem")
    )
    guard case .choosingInstallation = controller.state(for: second) else {
      return XCTFail("Expected admission to reopen")
    }
  }

  func testSavedConnectionCheckCoversSuccessPermissionDriftAndRepositoryRevocation() async throws {
    let namespaceID = UUID()
    let connection = try makeConnection()
    let validInstallation = makeInstallation(["issues": "write", "contents": "write"])
    let repository = GitHubRepository(
      id: 30,
      fullName: "octo/research",
      htmlURL: URL(string: "https://github.com/octo/research")!,
      isPrivate: true
    )
    let scenarios: [([GitHubInstallation], [GitHubRepository], String?)] = [
      ([validInstallation], [repository], nil),
      ([makeInstallation(["issues": "read", "contents": "write"])], [repository], "Issues"),
      ([makeInstallation(["issues": "write", "contents": "read"])], [repository], "Contents"),
      ([validInstallation], [], "repository is no longer accessible"),
    ]

    for (installations, repositories, failureText) in scenarios {
      let controller = GitHubConnectionController(
        broker: RecordingGitHubConnectionBroker(
          installations: installations,
          repositories: repositories
        ),
        credentialCleanup: RecordingGitHubCredentialCleanup()
      )
      await controller.check(connection, namespaceID: namespaceID)
      if let failureText {
        guard case .failed(let message) = controller.state(for: namespaceID) else {
          return XCTFail("Expected connection check failure")
        }
        XCTAssertTrue(message.contains(failureText), message)
      } else {
        XCTAssertEqual(controller.state(for: namespaceID), .verified)
      }
    }
  }

  func testDisconnectFailureRetainsConnectionAndUnmarksCleanup() async throws {
    let namespaceID = UUID()
    let cleanup = RecordingGitHubCredentialCleanup()
    let controller = GitHubConnectionController(
      broker: RecordingGitHubConnectionBroker(),
      credentialCleanup: cleanup
    )

    do {
      _ = try await controller.disconnect(namespaceID: namespaceID) {
        throw TestGitHubConnectionError.saveFailed
      }
      XCTFail("Expected metadata removal failure")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Connection save failed.")
    }
    let started = await cleanup.started
    let committed = await cleanup.committed
    let cleaned = await cleanup.cleaned
    XCTAssertEqual(started, [namespaceID])
    XCTAssertEqual(committed, [namespaceID])
    XCTAssertEqual(cleaned, [])
  }

  func testDisconnectCleanupWarningLeavesDisconnectedStateActionable() async throws {
    let namespaceID = UUID()
    let cleanup = RecordingGitHubCredentialCleanup(cleanupResults: [.success("Retry purge.")])
    let controller = GitHubConnectionController(
      broker: RecordingGitHubConnectionBroker(),
      credentialCleanup: cleanup
    )
    var removed = false

    let warning = try await controller.disconnect(namespaceID: namespaceID) { removed = true }

    XCTAssertTrue(removed)
    XCTAssertEqual(warning, "Retry purge.")
    XCTAssertEqual(controller.state(for: namespaceID), .failed("Retry purge."))
  }

  func testCancellationCleanupWarningCanBeRetried() async {
    let namespaceID = UUID()
    let cleanup = RecordingGitHubCredentialCleanup(
      cleanupResults: [.success("Retry purge."), .success(nil)]
    )
    let controller = GitHubConnectionController(
      broker: RecordingGitHubConnectionBroker(),
      credentialCleanup: cleanup
    )
    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )

    let firstWarning = await controller.cancelSetup(namespaceID: namespaceID)
    let retryWarning = await controller.cancelSetup(namespaceID: namespaceID)
    XCTAssertEqual(firstWarning, "Retry purge.")
    XCTAssertNil(retryWarning)
    XCTAssertEqual(controller.state(for: namespaceID), .idle)
    let cleaned = await cleanup.cleaned
    XCTAssertEqual(cleaned, [namespaceID, namespaceID])
  }

  func testSavedConnectionReportsBookkeepingFailureForRestartReconciliation() async throws {
    let namespaceID = UUID()
    let cleanup = RecordingGitHubCredentialCleanup(
      committedError: TestGitHubConnectionError.ledgerFailed
    )
    let controller = GitHubConnectionController(
      broker: RecordingGitHubConnectionBroker(),
      credentialCleanup: cleanup
    )
    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )
    guard case .choosingInstallation(_, let installations) = controller.state(for: namespaceID)
    else { return XCTFail("Expected installations") }
    await controller.chooseInstallation(installations[0], namespaceID: namespaceID)
    guard case .choosingRepository(_, _, let repositories) = controller.state(for: namespaceID)
    else { return XCTFail("Expected repositories") }
    var saved = false

    try await controller.connect(repositories[0], namespaceID: namespaceID) { _ in saved = true }

    XCTAssertTrue(saved)
    guard case .failed(let message) = controller.state(for: namespaceID) else {
      return XCTFail("Expected reconciliation warning")
    }
    XCTAssertTrue(message.contains("reconcile it after restart"))
  }

  func testFailedSetupStagesCleanUpBeforeDirectRetry() async throws {
    for stage in RetryingGitHubConnectionBroker.FailureStage.allCases {
      let namespaceID = UUID()
      let broker = RetryingGitHubConnectionBroker(failureStage: stage)
      let cleanup = RecordingGitHubCredentialCleanup()
      let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)

      await controller.beginConnection(
        namespaceID: namespaceID,
        appIDText: "10",
        privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
      )
      if stage == .repositories {
        guard case .choosingInstallation(_, let installations) = controller.state(for: namespaceID)
        else { return XCTFail("Expected first installation selection") }
        await controller.chooseInstallation(installations[0], namespaceID: namespaceID)
      }
      guard case .failed = controller.state(for: namespaceID) else {
        return XCTFail("Expected first \(stage) attempt to fail")
      }

      await controller.beginConnection(
        namespaceID: namespaceID,
        appIDText: "10",
        privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
      )
      guard case .choosingInstallation(_, let installations) = controller.state(for: namespaceID)
      else { return XCTFail("Expected retry to load installations") }
      if stage == .repositories {
        await controller.chooseInstallation(installations[0], namespaceID: namespaceID)
        guard case .choosingRepository = controller.state(for: namespaceID) else {
          return XCTFail("Expected repository retry to succeed")
        }
      }
      let cleaned = await cleanup.cleaned
      XCTAssertEqual(cleaned, [namespaceID])
    }
  }

  func testSaveRollbackWarningAndErrorRemainRetryableThroughCleanup() async throws {
    let cleanupFailures: [Result<String?, Error>] = [
      .success("Purge pending."),
      .failure(TestGitHubConnectionError.cleanupFailed),
    ]
    for failure in cleanupFailures {
      let namespaceID = UUID()
      let cleanup = RecordingGitHubCredentialCleanup(
        cleanupResults: [failure, .success(nil)]
      )
      let controller = GitHubConnectionController(
        broker: RecordingGitHubConnectionBroker(),
        credentialCleanup: cleanup
      )
      await controller.beginConnection(
        namespaceID: namespaceID,
        appIDText: "10",
        privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
      )
      guard case .choosingInstallation(_, let installations) = controller.state(for: namespaceID)
      else { return XCTFail("Expected installations") }
      await controller.chooseInstallation(installations[0], namespaceID: namespaceID)
      guard case .choosingRepository(_, _, let repositories) = controller.state(for: namespaceID)
      else { return XCTFail("Expected repositories") }

      do {
        try await controller.connect(repositories[0], namespaceID: namespaceID) { _ in
          throw TestGitHubConnectionError.saveFailed
        }
        XCTFail("Expected rollback failure")
      } catch {
        XCTAssertEqual(error.localizedDescription, GitHubConnectionSetupError.rollbackFailed.localizedDescription)
      }
      let retryWarning = await controller.cancelSetup(namespaceID: namespaceID)
      XCTAssertNil(retryWarning)
      XCTAssertEqual(controller.state(for: namespaceID), .idle)
    }
  }

  func testDisconnectLedgerRollbackFailureCanBeRetried() async throws {
    let namespaceID = UUID()
    let cleanup = RecordingGitHubCredentialCleanup(
      committedError: TestGitHubConnectionError.ledgerFailed
    )
    let controller = GitHubConnectionController(
      broker: RecordingGitHubConnectionBroker(),
      credentialCleanup: cleanup
    )
    do {
      _ = try await controller.disconnect(namespaceID: namespaceID) {
        throw TestGitHubConnectionError.saveFailed
      }
      XCTFail("Expected rollback bookkeeping failure")
    } catch {
      XCTAssertEqual(error.localizedDescription, GitHubConnectionSetupError.rollbackFailed.localizedDescription)
    }

    let warning = try await controller.disconnect(namespaceID: namespaceID) {}
    XCTAssertNil(warning)
    XCTAssertEqual(controller.state(for: namespaceID), .idle)
  }

  func testSetupLedgerFailureDoesNotImportPrivateKey() async {
    let namespaceID = UUID()
    let broker = RecordingGitHubConnectionBroker()
    let cleanup = RecordingGitHubCredentialCleanup(setupError: TestGitHubConnectionError.ledgerFailed)
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)

    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )

    let configured = await broker.configured
    XCTAssertEqual(configured, [])
    guard case .failed(let message) = controller.state(for: namespaceID) else {
      return XCTFail("Expected ledger failure")
    }
    XCTAssertEqual(message, "Cleanup ledger failed.")
  }

  func testPermissionRequirementMatrix() {
    let accepted = [["issues": "write", "contents": "write"]]
    for permissions in accepted {
      XCTAssertNoThrow(try GitHubPermissionRequirements.validate(makeInstallation(permissions)))
    }
    let rejected = [
      [:],
      ["issues": "read", "contents": "read"],
      ["issues": "none", "contents": "write"],
      ["issues": "read", "contents": "write"],
      ["issues": "write", "contents": "read"],
      ["issues": "write"],
      ["contents": "write"],
    ]
    for permissions in rejected {
      XCTAssertThrowsError(try GitHubPermissionRequirements.validate(makeInstallation(permissions)))
    }
    XCTAssertThrowsError(
      try GitHubPermissionRequirements.validate(makeInstallation(accepted[0], suspended: true))
    )
  }

  private func makeInstallation(
    _ permissions: [String: String],
    suspended: Bool = false
  ) -> GitHubInstallation {
    GitHubInstallation(
      id: 20,
      accountLogin: "octo",
      accountType: "Organization",
      permissions: permissions,
      isSuspended: suspended
    )
  }

  private func makeConnection() throws -> GitHubConnection {
    try GitHubConnection(
      appID: 10,
      installationID: 20,
      accountLogin: "octo",
      repositoryID: 30,
      repositoryFullName: "octo/research",
      repositoryURL: URL(string: "https://github.com/octo/research")!
    )
  }
}

private struct Configuration: Equatable, Sendable {
  let namespaceID: UUID
  let appID: Int64
  let keyURL: URL
}

private actor RecordingGitHubConnectionBroker: GitHubConnectionBrokering {
  private(set) var configured: [Configuration] = []
  private(set) var repositoryRequestCount = 0
  private let installations: [GitHubInstallation]
  private let repositories: [GitHubRepository]

  init(
    installations: [GitHubInstallation] = [
      GitHubInstallation(
        id: 20,
        accountLogin: "octo",
        accountType: "Organization",
        permissions: ["issues": "write", "contents": "write"],
        isSuspended: false
      )
    ],
    repositories: [GitHubRepository] = [
      GitHubRepository(
        id: 30,
        fullName: "octo/research",
        htmlURL: URL(string: "https://github.com/octo/research")!,
        isPrivate: true
      )
    ]
  ) {
    self.installations = installations
    self.repositories = repositories
  }

  func configureGitHubApp(
    appID: Int64,
    privateKeyFileURL: URL,
    namespaceID: UUID
  ) {
    configured.append(Configuration(namespaceID: namespaceID, appID: appID, keyURL: privateKeyFileURL))
  }

  func discoverGitHubInstallations(namespaceID: UUID) -> [GitHubInstallation] {
    installations
  }

  func discoverGitHubRepositories(
    installationID: Int64,
    namespaceID: UUID
  ) -> [GitHubRepository] {
    repositoryRequestCount += 1
    return repositories
  }

}

private actor RecordingGitHubCredentialCleanup: GitHubCredentialCleaning {
  private(set) var cleaned: [UUID] = []
  private(set) var started: [UUID] = []
  private(set) var committed: [UUID] = []
  private let operations: MainActorOperationRecorder?
  private let setupError: Error?
  private let committedError: Error?
  private let events: LifecycleEventRecorder?
  private var cleanupResults: [Result<String?, Error>]

  init(
    operations: MainActorOperationRecorder? = nil,
    setupError: Error? = nil,
    committedError: Error? = nil,
    events: LifecycleEventRecorder? = nil,
    cleanupResults: [Result<String?, Error>] = []
  ) {
    self.operations = operations
    self.setupError = setupError
    self.committedError = committedError
    self.events = events
    self.cleanupResults = cleanupResults
  }

  func setupStarted(_ namespaceID: UUID) async throws {
    if let setupError { throw setupError }
    started.append(namespaceID)
    await operations?.append("stage")
  }

  func cleanup(_ namespaceID: UUID) async throws -> String? {
    cleaned.append(namespaceID)
    await events?.append("cleanup")
    await operations?.append("purge")
    if !cleanupResults.isEmpty { return try cleanupResults.removeFirst().get() }
    return nil
  }

  func connectionCommitted(_ namespaceID: UUID) throws {
    committed.append(namespaceID)
    if let committedError { throw committedError }
  }
}

private actor GatedGitHubConnectionBroker: GitHubConnectionBrokering {
  enum GatePoint: Equatable {
    case configuration
    case installations
    case repositories
  }

  private let gate = AsyncGate()
  private let gatePoint: GatePoint
  private let events: LifecycleEventRecorder?
  private(set) var configured: [Configuration] = []

  init(gatePoint: GatePoint = .installations, events: LifecycleEventRecorder? = nil) {
    self.gatePoint = gatePoint
    self.events = events
  }

  func configureGitHubApp(appID: Int64, privateKeyFileURL: URL, namespaceID: UUID) async {
    configured.append(Configuration(namespaceID: namespaceID, appID: appID, keyURL: privateKeyFileURL))
    if gatePoint == .configuration {
      await events?.append("configuration-started")
      await gate.wait()
    }
    await events?.append("configuration-finished")
  }

  func discoverGitHubInstallations(namespaceID: UUID) async -> [GitHubInstallation] {
    if gatePoint == .installations {
      await events?.append("installations-started")
      await gate.wait()
    }
    await events?.append("installations-finished")
    return [
      GitHubInstallation(
        id: 20,
        accountLogin: "octo",
        accountType: "Organization",
        permissions: ["issues": "write", "contents": "write"],
        isSuspended: false
      )
    ]
  }

  func discoverGitHubRepositories(
    installationID: Int64,
    namespaceID: UUID
  ) async -> [GitHubRepository] {
    if gatePoint == .repositories { await gate.wait() }
    return [
      GitHubRepository(
        id: 30,
        fullName: "octo/research",
        htmlURL: URL(string: "https://github.com/octo/research")!,
        isPrivate: true
      )
    ]
  }

  func waitUntilInstallationDiscoveryStarts() async { await gate.waitUntilEntered() }
  func finishInstallationDiscovery() async { await gate.open() }
  func waitUntilGateStarts() async { await gate.waitUntilEntered() }
  func finishGate() async { await gate.open() }
}

private actor RetryingGitHubConnectionBroker: GitHubConnectionBrokering {
  enum FailureStage: CaseIterable, Equatable {
    case configuration
    case installations
    case repositories
  }

  private let failureStage: FailureStage
  private var configurationCalls = 0
  private var installationCalls = 0
  private var repositoryCalls = 0

  init(failureStage: FailureStage) {
    self.failureStage = failureStage
  }

  func configureGitHubApp(appID: Int64, privateKeyFileURL: URL, namespaceID: UUID) throws {
    configurationCalls += 1
    if failureStage == .configuration, configurationCalls == 1 {
      throw TestGitHubConnectionError.serviceFailed
    }
  }

  func discoverGitHubInstallations(namespaceID: UUID) -> [GitHubInstallation] {
    installationCalls += 1
    if failureStage == .installations, installationCalls == 1 { return [] }
    return [
      GitHubInstallation(
        id: 20,
        accountLogin: "octo",
        accountType: "Organization",
        permissions: ["issues": "write", "contents": "write"],
        isSuspended: false
      )
    ]
  }

  func discoverGitHubRepositories(
    installationID: Int64,
    namespaceID: UUID
  ) -> [GitHubRepository] {
    repositoryCalls += 1
    if failureStage == .repositories, repositoryCalls == 1 { return [] }
    return [
      GitHubRepository(
        id: 30,
        fullName: "octo/research",
        htmlURL: URL(string: "https://github.com/octo/research")!,
        isPrivate: true
      )
    ]
  }
}

private actor AsyncGate {
  private var entered = false
  private var isOpen = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered = true
    entryWaiters.forEach { $0.resume() }
    entryWaiters.removeAll()
    if isOpen { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func open() {
    isOpen = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

private actor LifecycleEventRecorder {
  private(set) var values: [String] = []
  func append(_ value: String) { values.append(value) }
}

@MainActor
private final class MainActorOperationRecorder: @unchecked Sendable {
  private(set) var values: [String] = []
  func append(_ value: String) { values.append(value) }
}

private enum TestGitHubConnectionError: LocalizedError {
  case saveFailed
  case ledgerFailed
  case cleanupFailed
  case serviceFailed
  var errorDescription: String? {
    switch self {
    case .saveFailed: "Connection save failed."
    case .ledgerFailed: "Cleanup ledger failed."
    case .cleanupFailed: "Cleanup failed."
    case .serviceFailed: "GitHub service failed."
    }
  }
}
