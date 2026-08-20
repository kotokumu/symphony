import Combine
import Foundation
import SymphonyDesktopCore

protocol NamespaceCredentialBrokering: Sendable {
  func unlock(namespaceID: Namespace.ID) async throws
  func lock(namespaceID: Namespace.ID) async throws
  func lockAll() async throws
  func shutdownForApplicationTermination() async throws
  func resumeAfterApplicationTerminationFailure() async
  func removeNamespace(_ namespaceID: Namespace.ID) async throws
  func isUnlocked(_ namespaceID: Namespace.ID) async -> Bool
}

@MainActor
final class NamespaceLockController: ObservableObject {
  @Published private(set) var states: [Namespace.ID: NamespaceLockState] = [:]

  private let broker: any NamespaceCredentialBrokering

  init(broker: any NamespaceCredentialBrokering) {
    self.broker = broker
  }

  func state(for namespaceID: Namespace.ID) -> NamespaceLockState {
    states[namespaceID] ?? .locked()
  }

  func unlock(_ namespaceID: Namespace.ID) async {
    switch state(for: namespaceID) {
    case .unlocking, .unlocked:
      return
    case .locked, .lockFailed:
      break
    }

    states[namespaceID] = .unlocking
    do {
      try await broker.unlock(namespaceID: namespaceID)
      states[namespaceID] = .unlocked
    } catch {
      states[namespaceID] = .locked(message: error.localizedDescription)
    }
  }

  func lock(_ namespaceID: Namespace.ID) async throws {
    do {
      try await broker.lock(namespaceID: namespaceID)
      states[namespaceID] = .locked()
    } catch {
      states[namespaceID] = .lockFailed(message: error.localizedDescription)
      throw error
    }
  }

  func lockAll() async throws {
    do {
      try await broker.lockAll()
      for namespaceID in states.keys {
        states[namespaceID] = .locked()
      }
    } catch {
      await refreshOwnedStates(after: error)
      throw error
    }
  }

  func shutdownForApplicationTermination() async throws {
    do {
      try await broker.shutdownForApplicationTermination()
      for namespaceID in states.keys {
        states[namespaceID] = .locked()
      }
    } catch {
      await refreshOwnedStates(after: error)
      throw error
    }
  }

  func resumeAfterApplicationTerminationFailure() async {
    await broker.resumeAfterApplicationTerminationFailure()
  }

  func removeNamespace(_ namespaceID: Namespace.ID) async throws {
    do {
      try await broker.removeNamespace(namespaceID)
      states.removeValue(forKey: namespaceID)
    } catch {
      states[namespaceID] = .lockFailed(message: error.localizedDescription)
      throw error
    }
  }

  private func refreshOwnedStates(after error: Error) async {
    for namespaceID in states.keys {
      if await broker.isUnlocked(namespaceID) {
        states[namespaceID] = .lockFailed(message: error.localizedDescription)
      } else {
        states[namespaceID] = .locked()
      }
    }
  }
}
