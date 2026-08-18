import Combine
import Foundation
import SymphonyDesktopCore

protocol NamespaceDaemonSupervising: Sendable {
  func events() async -> AsyncStream<NamespaceDaemonEvent>
  func start(namespaceID: Namespace.ID, namespaceDirectory: URL) async
  func stop(namespaceID: Namespace.ID) async throws
  func stopAll() async throws
}

@MainActor
final class NamespaceDaemonController: ObservableObject {
  @Published private(set) var states: [Namespace.ID: NamespaceDaemonState] = [:]

  private let supervisor: any NamespaceDaemonSupervising
  private let directoryURL: @Sendable (Namespace.ID) -> URL
  private var eventStreamTask: Task<AsyncStream<NamespaceDaemonEvent>, Never>?
  private var observationTask: Task<Void, Never>?

  init(
    supervisor: any NamespaceDaemonSupervising,
    directoryURL: @escaping @Sendable (Namespace.ID) -> URL
  ) {
    self.supervisor = supervisor
    self.directoryURL = directoryURL
  }

  deinit {
    eventStreamTask?.cancel()
    observationTask?.cancel()
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
      }
    }
  }

  func state(for namespaceID: Namespace.ID) -> NamespaceDaemonState {
    states[namespaceID] ?? .stopped
  }

  func start(_ namespace: DesktopNamespace) async {
    await startObserving()
    await supervisor.start(
      namespaceID: namespace.id,
      namespaceDirectory: directoryURL(namespace.id)
    )
  }

  func stop(_ namespaceID: Namespace.ID) async throws {
    try await supervisor.stop(namespaceID: namespaceID)
  }

  func restart(_ namespace: DesktopNamespace) async throws {
    try await stop(namespace.id)
    await start(namespace)
  }

  func stopAll() async throws {
    try await supervisor.stopAll()
  }
}
