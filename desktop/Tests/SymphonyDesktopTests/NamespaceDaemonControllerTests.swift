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

  func testConcurrentObservationRequestsCreateOneSubscription() async {
    let supervisor = TestDaemonSupervisor(suspendEventSubscription: true)
    let controller = NamespaceDaemonController(
      supervisor: supervisor,
      directoryURL: { id in URL(fileURLWithPath: "/namespaces/\(id.uuidString)") }
    )

    let first = Task { await controller.startObserving() }
    while await supervisor.eventSubscriptionCount == 0 {
      await Task.yield()
    }
    let second = Task { await controller.startObserving() }
    await Task.yield()

    let requestCount = await supervisor.eventSubscriptionCount
    XCTAssertEqual(requestCount, 1)

    await supervisor.resumeEventSubscription()
    await first.value
    await second.value
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

private actor TestDaemonSupervisor: NamespaceDaemonSupervising {
  enum Operation: Equatable {
    case start(Namespace.ID, URL)
    case stop(Namespace.ID)
  }

  private(set) var operations: [Operation] = []
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

  func start(namespaceID: Namespace.ID, namespaceDirectory: URL) {
    operations.append(.start(namespaceID, namespaceDirectory))
    continuation?.yield(.init(namespaceID: namespaceID, state: .starting))
  }

  func stop(namespaceID: Namespace.ID) {
    operations.append(.stop(namespaceID))
    continuation?.yield(.init(namespaceID: namespaceID, state: .stopped))
  }

  func stopAll() throws {}

  func emit(_ event: NamespaceDaemonEvent) {
    continuation?.yield(event)
  }

  func resumeEventSubscription() {
    shouldSuspendEventSubscription = false
    eventSubscriptionContinuation?.resume()
    eventSubscriptionContinuation = nil
  }
}
