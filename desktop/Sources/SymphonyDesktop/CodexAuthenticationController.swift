import Combine
import Foundation
import SymphonyDesktopCore

protocol CodexAuthenticating: Sendable {
  func events() async -> AsyncStream<CodexAuthenticationEvent>
  func refresh(namespaceID: Namespace.ID, namespaceDirectory: URL) async
  func signIn(namespaceID: Namespace.ID, namespaceDirectory: URL) async
  func signOut(namespaceID: Namespace.ID, namespaceDirectory: URL) async
}

@MainActor
final class CodexAuthenticationController: ObservableObject {
  @Published private(set) var states: [Namespace.ID: CodexAuthenticationState] = [:]

  private let authenticator: any CodexAuthenticating
  private let directoryURL: @Sendable (Namespace.ID) -> URL
  private var eventStreamTask: Task<AsyncStream<CodexAuthenticationEvent>, Never>?
  private var observationTask: Task<Void, Never>?
  private var operations: [Namespace.ID: (generation: UUID, task: Task<Void, Never>)] = [:]

  init(
    authenticator: any CodexAuthenticating,
    directoryURL: @escaping @Sendable (Namespace.ID) -> URL
  ) {
    self.authenticator = authenticator
    self.directoryURL = directoryURL
  }

  deinit {
    eventStreamTask?.cancel()
    observationTask?.cancel()
    for operation in operations.values {
      operation.task.cancel()
    }
  }

  func startObserving() async {
    if observationTask != nil {
      return
    }
    if eventStreamTask == nil {
      eventStreamTask = Task { [authenticator] in
        await authenticator.events()
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

  func state(for namespaceID: Namespace.ID) -> CodexAuthenticationState {
    states[namespaceID] ?? .signedOut
  }

  func refresh(_ namespaceID: Namespace.ID) async {
    await startObserving()
    let directory = directoryURL(namespaceID)
    await replaceOperation(for: namespaceID) { [authenticator] in
      await authenticator.refresh(
        namespaceID: namespaceID,
        namespaceDirectory: directory
      )
    }
  }

  func signIn(_ namespaceID: Namespace.ID) async {
    await startObserving()
    let directory = directoryURL(namespaceID)
    await replaceOperation(for: namespaceID) { [authenticator] in
      await authenticator.signIn(
        namespaceID: namespaceID,
        namespaceDirectory: directory
      )
    }
  }

  func signOut(_ namespaceID: Namespace.ID) async {
    await startObserving()
    let directory = directoryURL(namespaceID)
    await replaceOperation(for: namespaceID) { [authenticator] in
      await authenticator.signOut(
        namespaceID: namespaceID,
        namespaceDirectory: directory
      )
    }
  }

  func cancel(_ namespaceID: Namespace.ID) async {
    guard let operation = operations[namespaceID] else {
      return
    }
    operation.task.cancel()
    await operation.task.value
    if operations[namespaceID]?.generation == operation.generation {
      operations.removeValue(forKey: namespaceID)
    }
  }

  func cancelAll() async {
    let activeOperations = operations
    for operation in activeOperations.values {
      operation.task.cancel()
    }
    for (namespaceID, operation) in activeOperations {
      await operation.task.value
      if operations[namespaceID]?.generation == operation.generation {
        operations.removeValue(forKey: namespaceID)
      }
    }
  }

  private func replaceOperation(
    for namespaceID: Namespace.ID,
    with operation: @escaping @MainActor () async -> Void
  ) async {
    await cancel(namespaceID)
    let generation = UUID()
    let task = Task { @MainActor in
      await operation()
    }
    operations[namespaceID] = (generation, task)
    await task.value
    if operations[namespaceID]?.generation == generation {
      operations.removeValue(forKey: namespaceID)
    }
  }
}
