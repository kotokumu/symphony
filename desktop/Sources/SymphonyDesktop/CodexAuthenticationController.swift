import Combine
import Foundation
import SymphonyDesktopCore

protocol CodexAuthenticating: Sendable {
  func events() async -> AsyncStream<CodexAuthenticationEvent>
  func refresh(namespaceID: Namespace.ID, namespaceDirectory: URL) async
  func signIn(namespaceID: Namespace.ID, namespaceDirectory: URL) async
  func signOut(namespaceID: Namespace.ID, namespaceDirectory: URL) async
  func cancelAll() async throws
}

@MainActor
final class CodexAuthenticationController: ObservableObject {
  @Published private(set) var states: [Namespace.ID: CodexAuthenticationState] = [:]

  private let authenticator: any CodexAuthenticating
  private let directoryURL: @Sendable (Namespace.ID) -> URL
  private var eventStreamTask: Task<AsyncStream<CodexAuthenticationEvent>, Never>?
  private var observationTask: Task<Void, Never>?

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
    await authenticator.refresh(
      namespaceID: namespaceID,
      namespaceDirectory: directoryURL(namespaceID)
    )
  }

  func signIn(_ namespaceID: Namespace.ID) async {
    await startObserving()
    await authenticator.signIn(
      namespaceID: namespaceID,
      namespaceDirectory: directoryURL(namespaceID)
    )
  }

  func signOut(_ namespaceID: Namespace.ID) async {
    await startObserving()
    await authenticator.signOut(
      namespaceID: namespaceID,
      namespaceDirectory: directoryURL(namespaceID)
    )
  }

  func cancelAll() async throws {
    try await authenticator.cancelAll()
  }
}
