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
  private var sleepProtectionAvailable: Bool

  init(
    broker: any NamespaceCredentialBrokering,
    sleepProtectionAvailable: Bool = true
  ) {
    self.broker = broker
    self.sleepProtectionAvailable = sleepProtectionAvailable
  }

  func state(for namespaceID: Namespace.ID) -> NamespaceLockState {
    states[namespaceID] ?? .locked()
  }

  func unlock(_ namespaceID: Namespace.ID) async {
    guard sleepProtectionAvailable else {
      states[namespaceID] = .locked(
        message: "Credentials cannot be unlocked because system sleep protection is unavailable."
      )
      return
    }
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

  func setSleepProtectionAvailable(_ available: Bool) {
    sleepProtectionAvailable = available
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
