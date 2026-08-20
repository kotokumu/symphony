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
  private let afterStop: @Sendable (Namespace.ID) async throws -> Void
  private let afterStopAll: @Sendable () async throws -> Void
  private var eventStreamTask: Task<AsyncStream<NamespaceDaemonEvent>, Never>?
  private var observationTask: Task<Void, Never>?

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
}
