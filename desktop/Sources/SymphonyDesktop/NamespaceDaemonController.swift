import Combine
import Foundation
import SymphonyDesktopCore
import SymphonyDesktopInfrastructure

protocol NamespaceDaemonSupervising: Sendable {
  func events() async -> AsyncStream<NamespaceDaemonEvent>
  func configure(namespaceID: Namespace.ID, tracker: NamespaceDaemonTrackerConfiguration) async
  func start(namespaceID: Namespace.ID, namespaceDirectory: URL) async
  func stop(namespaceID: Namespace.ID) async throws
  func stopAll() async throws
  func issueRuns(namespaceID: Namespace.ID) async throws -> [NamespaceIssueRun]
  func issueAction(
    namespaceID: Namespace.ID,
    issueIdentifier: String,
    action: NamespaceIssueAction
  ) async throws -> NamespaceIssueActionResult
}

@MainActor
final class NamespaceDaemonController: ObservableObject {
  @Published private(set) var states: [Namespace.ID: NamespaceDaemonState] = [:]
  @Published private(set) var issueRuns: [Namespace.ID: [NamespaceIssueRun]] = [:]
  @Published private(set) var issueRunErrors: [Namespace.ID: String] = [:]

  private let supervisor: any NamespaceDaemonSupervising
  private let directoryURL: @Sendable (Namespace.ID) -> URL
  private let afterStop: @Sendable (Namespace.ID) async throws -> Void
  private let afterStopAll: @Sendable () async throws -> Void
  private var eventStreamTask: Task<AsyncStream<NamespaceDaemonEvent>, Never>?
  private var observationTask: Task<Void, Never>?
  private var issuePollingTask: Task<Void, Never>?

  init(
    supervisor: any NamespaceDaemonSupervising,
    directoryURL: @escaping @Sendable (Namespace.ID) -> URL,
    afterStop: @escaping @Sendable (Namespace.ID) async throws -> Void = { _ in },
    afterStopAll: @escaping @Sendable () async throws -> Void = {}
  ) {
    self.supervisor = supervisor
    self.directoryURL = directoryURL
    self.afterStop = afterStop
    self.afterStopAll = afterStopAll
  }

  deinit {
    eventStreamTask?.cancel()
    observationTask?.cancel()
    issuePollingTask?.cancel()
  }

  func startObserving() async {
    if observationTask != nil {
      return
    }
    if eventStreamTask == nil {
      eventStreamTask = Task { [supervisor] in
        await supervisor.events()
      }
    }
    guard let eventStreamTask else {
      return
    }
    let events = await eventStreamTask.value
    guard observationTask == nil else {
      return
    }
    observationTask = Task { [weak self] in
      for await event in events {
        guard !Task.isCancelled else {
          return
        }
        self?.states[event.namespaceID] = event.state
        if case .failed = event.state {
          try? await self?.afterStop(event.namespaceID)
        }
      }
    }
    issuePollingTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshIssueRuns()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func state(for namespaceID: Namespace.ID) -> NamespaceDaemonState {
    states[namespaceID] ?? .stopped
  }

  func start(_ namespace: DesktopNamespace) async {
    await startObserving()
    let tracker: NamespaceDaemonTrackerConfiguration
    if case .github(let connection) = namespace.platformConnection {
      tracker = .github(repository: connection.repositoryFullName)
    } else {
      tracker = .memory
    }
    await supervisor.configure(namespaceID: namespace.id, tracker: tracker)
    await supervisor.start(
      namespaceID: namespace.id,
      namespaceDirectory: directoryURL(namespace.id)
    )
  }

  func stop(_ namespaceID: Namespace.ID) async throws {
    try await supervisor.stop(namespaceID: namespaceID)
    try await afterStop(namespaceID)
  }

  func restart(_ namespace: DesktopNamespace) async throws {
    try await stop(namespace.id)
    await start(namespace)
  }

  func stopAll() async throws {
    try await supervisor.stopAll()
    try await afterStopAll()
  }

  func refreshIssueRuns() async {
    for namespaceID in states.keys {
      guard case .running = states[namespaceID] else { continue }
      do {
        let runs = try await supervisor.issueRuns(namespaceID: namespaceID)
        issueRuns[namespaceID] = runs
        issueRunErrors.removeValue(forKey: namespaceID)
      } catch {
        issueRunErrors[namespaceID] = error.localizedDescription
      }
    }
  }

  func startIssue(_ identifier: String, in namespaceID: Namespace.ID) async throws {
    _ = try await supervisor.issueAction(
      namespaceID: namespaceID,
      issueIdentifier: identifier,
      action: .start
    )
    issueRuns[namespaceID]?.removeAll { $0.issueIdentifier == identifier }
    await refreshIssueRuns()
  }

  func stopIssue(_ identifier: String, in namespaceID: Namespace.ID) async throws {
    let result = try await supervisor.issueAction(
      namespaceID: namespaceID,
      issueIdentifier: identifier,
      action: .stop
    )
    await refreshIssueRuns()
    issueRuns[namespaceID, default: []].removeAll { $0.issueIdentifier == identifier }
    issueRuns[namespaceID, default: []].append(
      NamespaceIssueRun(issueIdentifier: result.issueIdentifier, status: result.status)
    )
  }

  func retryIssue(_ identifier: String, in namespaceID: Namespace.ID) async throws {
    _ = try await supervisor.issueAction(
      namespaceID: namespaceID,
      issueIdentifier: identifier,
      action: .retry
    )
    issueRuns[namespaceID]?.removeAll { $0.issueIdentifier == identifier }
    await refreshIssueRuns()
  }
}
