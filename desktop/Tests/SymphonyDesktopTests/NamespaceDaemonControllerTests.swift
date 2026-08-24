import Foundation
import XCTest

@testable import SymphonyDesktop
@testable import SymphonyDesktopCore

@MainActor
final class NamespaceDaemonControllerTests: XCTestCase {
  func testStartsAStoppedNamespaceAndPublishesReadiness() async throws {
    let namespace = try makeNamespace(named: "Research")
    let supervisor = TestDaemonSupervisor()
    let directory = URL(fileURLWithPath: "/namespaces/research", isDirectory: true)
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { _ in directory }
    )
    await controller.startObserving()

    await controller.start(namespace)

    await eventually {
      controller.state(for: namespace.id) == .starting
    }
    await supervisor.emit(
      NamespaceDaemonEvent(
        namespaceID: namespace.id,
        state: .running(endpoint: URL(string: "http://127.0.0.1:43123")!)
      )
    )

    await eventually {
      controller.state(for: namespace.id)
        == .running(endpoint: URL(string: "http://127.0.0.1:43123")!)
    }
    let operations = await supervisor.operations
    XCTAssertEqual(operations, [.start(namespace.id, directory)])
  }

  func testUnexpectedFailureOnlyChangesTheMatchingNamespace() async throws {
    let first = try makeNamespace(named: "Research")
    let second = try makeNamespace(named: "Operations")
    let supervisor = TestDaemonSupervisor()
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { id in URL(fileURLWithPath: "/namespaces/\(id.uuidString)") }
    )
    await controller.startObserving()

    await supervisor.emit(.init(namespaceID: first.id, state: .running(endpoint: endpoint(41001))))
    await supervisor.emit(.init(namespaceID: second.id, state: .running(endpoint: endpoint(41002))))
    await supervisor.emit(
      .init(namespaceID: first.id, state: .failed(message: "Symphony exited with status 2."))
    )

    await eventually {
      controller.state(for: first.id) == .failed(message: "Symphony exited with status 2.")
        && controller.state(for: second.id) == .running(endpoint: self.endpoint(41002))
    }
  }

  func testRestartWaitsForStopBeforeStartingReplacement() async throws {
    let namespace = try makeNamespace(named: "Research")
    let supervisor = TestDaemonSupervisor()
    let directory = URL(fileURLWithPath: "/namespaces/research", isDirectory: true)
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { _ in directory }
    )

    try await controller.restart(namespace)

    let operations = await supervisor.operations
    XCTAssertEqual(operations, [.stop(namespace.id), .start(namespace.id, directory)])
  }

  func testStoppingDaemonLocksTheMatchingNamespaceAfterProcessExit() async throws {
    let namespace = try makeNamespace(named: "Research")
    let supervisor = TestDaemonSupervisor()
    let operations = DaemonLifecycleRecorder()
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { _ in URL(fileURLWithPath: "/namespaces/research") },
      afterStop: { namespaceID in
        operations.append(.locked(namespaceID))
      }
    )

    try await controller.stop(namespace.id)

    let supervisorOperations = await supervisor.operations
    XCTAssertEqual(operations.values, [.locked(namespace.id)])
    XCTAssertEqual(supervisorOperations, [.stop(namespace.id)])
  }

  func testUnexpectedDaemonFailureLocksOnlyTheAffectedNamespace() async throws {
    let first = try makeNamespace(named: "Research")
    let second = try makeNamespace(named: "Operations")
    let supervisor = TestDaemonSupervisor()
    let operations = DaemonLifecycleRecorder()
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { id in URL(fileURLWithPath: "/namespaces/\(id.uuidString)") },
      afterStop: { namespaceID in
        operations.append(.locked(namespaceID))
      }
    )
    await controller.startObserving()

    await supervisor.emit(
      .init(namespaceID: first.id, state: .failed(message: "Daemon exited."))
    )

    await eventually {
      operations.values == [.locked(first.id)]
    }
    XCTAssertFalse(operations.values.contains(.locked(second.id)))
  }

  func testStoppingAllDaemonsLocksAllNamespaceCredentials() async throws {
    let supervisor = TestDaemonSupervisor()
    let operations = DaemonLifecycleRecorder()
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { id in URL(fileURLWithPath: "/namespaces/\(id.uuidString)") },
      afterStopAll: {
        operations.append(.lockedAll)
      }
    )

    try await controller.stopAll()

    XCTAssertEqual(operations.values, [.lockedAll])
  }

  func testConcurrentObservationRequestsCreateOneSubscription() async {
    let supervisor = TestDaemonSupervisor(suspendEventSubscription: true)
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { id in URL(fileURLWithPath: "/namespaces/\(id.uuidString)") }
    )

    let first = Task { await controller.startObserving() }
    let deadline = Date().addingTimeInterval(1)
    while await supervisor.eventSubscriptionCount == 0, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let initialRequestCount = await supervisor.eventSubscriptionCount
    XCTAssertEqual(initialRequestCount, 1)
    let second = Task { await controller.startObserving() }
    await Task.yield()

    let finalRequestCount = await supervisor.eventSubscriptionCount
    XCTAssertEqual(finalRequestCount, 1)

    await supervisor.resumeEventSubscription()
    await first.value
    await second.value
  }

  func testRefreshIssueRunsReadsOnlyRunningNamespacesAndKeepsTheirStateSeparate() async throws {
    let first = try makeNamespace(named: "Research")
    let second = try makeNamespace(named: "Operations")
    let supervisor = TestDaemonSupervisor()
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { id in URL(fileURLWithPath: "/namespaces/\(id.uuidString)") }
    )
    await controller.startObserving()

    let firstRun = NamespaceIssueRun(
      issueIdentifier: "GH-11",
      issueURL: URL(string: "https://github.com/acme/research/issues/11"),
      status: "running",
      workspacePath: "/namespaces/\(first.id)/Workspaces/GH-11"
    )
    let secondRun = NamespaceIssueRun(
      issueIdentifier: "GH-22",
      issueURL: URL(string: "https://github.com/acme/operations/issues/22"),
      status: "blocked",
      error: "Codex requires operator input",
      workspacePath: "/namespaces/\(second.id)/Workspaces/GH-22"
    )
    await supervisor.setIssueRuns([firstRun], for: first.id)
    await supervisor.setIssueRuns([secondRun], for: second.id)
    await supervisor.emit(.init(namespaceID: first.id, state: .running(endpoint: endpoint(43101))))
    await supervisor.emit(.init(namespaceID: second.id, state: .failed(message: "Daemon exited.")))

    await eventually {
      controller.state(for: first.id) == .running(endpoint: self.endpoint(43101))
        && controller.state(for: second.id) == .failed(message: "Daemon exited.")
    }
    await supervisor.resetIssueOperations()

    await controller.refreshIssueRuns()

    let issueRuns = await supervisor.issueRunRequests
    XCTAssertEqual(controller.issueRuns[first.id], [firstRun])
    XCTAssertNil(controller.issueRuns[second.id])
    XCTAssertEqual(issueRuns, [first.id])
  }

  func testIssueActionsUseTheRequestedNamespaceAndRefreshOnlyThatNamespace() async throws {
    let first = try makeNamespace(named: "Research")
    let second = try makeNamespace(named: "Operations")
    let supervisor = TestDaemonSupervisor()
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { id in URL(fileURLWithPath: "/namespaces/\(id.uuidString)") }
    )
    await controller.startObserving()
    await supervisor.emit(.init(namespaceID: first.id, state: .running(endpoint: endpoint(43201))))
    await supervisor.emit(.init(namespaceID: second.id, state: .running(endpoint: endpoint(43202))))
    await eventually {
      controller.state(for: first.id) == .running(endpoint: self.endpoint(43201))
        && controller.state(for: second.id) == .running(endpoint: self.endpoint(43202))
    }
    await supervisor.resetIssueOperations()

    try await controller.startIssue("GH-11", in: first.id)
    try await controller.stopIssue("GH-22", in: second.id)
    try await controller.retryIssue("GH-33", in: first.id)

    let actionRequests = await supervisor.issueActionRequests
    let issueRunRequests = await supervisor.issueRunRequests
    XCTAssertEqual(
      actionRequests,
      [
        .init(namespaceID: first.id, issueIdentifier: "GH-11", action: .start),
        .init(namespaceID: second.id, issueIdentifier: "GH-22", action: .stop),
        .init(namespaceID: first.id, issueIdentifier: "GH-33", action: .retry),
      ]
    )
    XCTAssertEqual(
      issueRunRequests,
      [first.id, second.id, first.id, second.id, first.id, second.id]
    )
    XCTAssertEqual(controller.issueRuns[second.id]?.map(\.status), ["stopped"])
  }

  private func makeNamespace(named name: String) throws -> DesktopNamespace {
    DesktopNamespace(id: UUID(), name: try NamespaceName(validating: name))
  }

  private func endpoint(_ port: Int) -> URL {
    URL(string: "http://127.0.0.1:\(port)")!
  }

  private func eventually(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      if condition() {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not satisfied", file: file, line: line)
  }
}

private final class DaemonLifecycleRecorder: @unchecked Sendable {
  enum Operation: Equatable {
    case locked(UUID)
    case lockedAll
  }

  private let lock = NSLock()
  private var storage: [Operation] = []

  func append(_ operation: Operation) {
    lock.withLock { storage.append(operation) }
  }

  var values: [Operation] {
    lock.withLock { storage }
  }
}

private actor TestDaemonSupervisor: NamespaceDaemonSupervising {
  enum Operation: Equatable {
    case start(Namespace.ID, URL)
    case stop(Namespace.ID)
  }

  struct IssueActionRequest: Equatable {
    let namespaceID: Namespace.ID
    let issueIdentifier: String
    let action: NamespaceIssueAction

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.namespaceID == rhs.namespaceID
        && lhs.issueIdentifier == rhs.issueIdentifier
        && lhs.action.rawValue == rhs.action.rawValue
    }
  }

  private(set) var operations: [Operation] = []
  private(set) var issueRunRequests: [Namespace.ID] = []
  private(set) var issueActionRequests: [IssueActionRequest] = []
  private var configuredIssueRuns: [Namespace.ID: [NamespaceIssueRun]] = [:]
  private(set) var eventSubscriptionCount = 0
  private var continuation: AsyncStream<NamespaceDaemonEvent>.Continuation?
  private var shouldSuspendEventSubscription: Bool
  private var eventSubscriptionContinuation: CheckedContinuation<Void, Never>?

  init(suspendEventSubscription: Bool = false) {
    shouldSuspendEventSubscription = suspendEventSubscription
  }

  func events() async -> AsyncStream<NamespaceDaemonEvent> {
    eventSubscriptionCount += 1
    if shouldSuspendEventSubscription {
      await withCheckedContinuation { continuation in
        eventSubscriptionContinuation = continuation
      }
    }
    return AsyncStream { continuation in
      self.continuation = continuation
    }
  }

  func configure(namespaceID: Namespace.ID, tracker: NamespaceDaemonTrackerConfiguration) async {}

  func start(namespaceID: Namespace.ID, namespaceDirectory: URL) {
    operations.append(.start(namespaceID, namespaceDirectory))
    continuation?.yield(.init(namespaceID: namespaceID, state: .starting))
  }

  func stop(namespaceID: Namespace.ID) {
    operations.append(.stop(namespaceID))
    continuation?.yield(.init(namespaceID: namespaceID, state: .stopped))
  }

  func stopAll() throws {}

  func issueRuns(namespaceID: Namespace.ID) async throws -> [NamespaceIssueRun] {
    issueRunRequests.append(namespaceID)
    return configuredIssueRuns[namespaceID] ?? []
  }

  func issueAction(
    namespaceID: Namespace.ID,
    issueIdentifier: String,
    action: NamespaceIssueAction
  ) async throws -> NamespaceIssueActionResult {
    issueActionRequests.append(.init(
      namespaceID: namespaceID,
      issueIdentifier: issueIdentifier,
      action: action
    ))
    let status = action == .stop ? "stopped" : "running"
    return NamespaceIssueActionResult(issueIdentifier: issueIdentifier, status: status)
  }

  func setIssueRuns(_ runs: [NamespaceIssueRun], for namespaceID: Namespace.ID) {
    configuredIssueRuns[namespaceID] = runs
  }

  func resetIssueOperations() {
    issueRunRequests.removeAll()
    issueActionRequests.removeAll()
  }

  func emit(_ event: NamespaceDaemonEvent) {
    continuation?.yield(event)
  }

  func resumeEventSubscription() {
    shouldSuspendEventSubscription = false
    eventSubscriptionContinuation?.resume()
    eventSubscriptionContinuation = nil
  }
}
