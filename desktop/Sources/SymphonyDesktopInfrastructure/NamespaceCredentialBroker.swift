import Foundation
import SymphonyDesktopCore

public actor NamespaceCredentialBroker {
  private struct PendingUnlock {
    let generation: UUID
    let task: Task<any CredentialBrokerSessionHandle, Error>
  }

  private let launcher: any CredentialBrokerSessionLaunching
  private var sessions: [Namespace.ID: any CredentialBrokerSessionHandle] = [:]
  private var pendingUnlocks: [Namespace.ID: PendingUnlock] = [:]
  private var lockingNamespaces: Set<Namespace.ID> = []
  private var startSuspensionCount = 0
  private var applicationTerminationRequested = false

  public init(launcher: any CredentialBrokerSessionLaunching) {
    self.launcher = launcher
  }

  public func unlock(namespaceID: Namespace.ID) async throws {
    guard sessions[namespaceID] == nil else {
      return
    }
    guard
      pendingUnlocks[namespaceID] == nil,
      !lockingNamespaces.contains(namespaceID),
      startSuspensionCount == 0,
      !applicationTerminationRequested
    else {
      throw NamespaceCredentialBrokerError.unlockUnavailable
    }

    let generation = UUID()
    let task = Task { [launcher] in
      try await launcher.unlock(namespaceID: namespaceID)
    }
    pendingUnlocks[namespaceID] = PendingUnlock(generation: generation, task: task)

    do {
      let session = try await task.value
      guard
        pendingUnlocks[namespaceID]?.generation == generation,
        !lockingNamespaces.contains(namespaceID),
        startSuspensionCount == 0,
        !applicationTerminationRequested
      else {
        try await session.lock()
        throw NamespaceCredentialBrokerError.unlockInterrupted
      }
      pendingUnlocks.removeValue(forKey: namespaceID)
      sessions[namespaceID] = session
    } catch {
      do {
        try await launcher.stop(namespaceID: namespaceID)
        if pendingUnlocks[namespaceID]?.generation == generation {
          pendingUnlocks.removeValue(forKey: namespaceID)
        }
      } catch {
        throw error
      }
      throw error
    }
  }

  public func lock(namespaceID: Namespace.ID) async throws {
    guard lockingNamespaces.insert(namespaceID).inserted else {
      throw NamespaceCredentialBrokerError.lockInProgress
    }
    defer { lockingNamespaces.remove(namespaceID) }

    if let pending = pendingUnlocks[namespaceID] {
      pending.task.cancel()
      _ = try? await pending.task.value
      try await launcher.stop(namespaceID: namespaceID)
      pendingUnlocks.removeValue(forKey: namespaceID)
    }
    guard let session = sessions[namespaceID] else {
      return
    }
    try await session.lock()
    sessions.removeValue(forKey: namespaceID)
  }

  public func signChallenge(_ challenge: Data, namespaceID: Namespace.ID) async throws -> Data {
    guard let session = sessions[namespaceID] else {
      throw NamespaceCredentialBrokerError.locked
    }
    return try await session.signChallenge(challenge)
  }

  public func lockAll() async throws {
    startSuspensionCount += 1
    defer { startSuspensionCount -= 1 }
    try await lockAllOwnedSessions()
  }

  public func shutdownForApplicationTermination() async throws {
    applicationTerminationRequested = true
    do {
      try await lockAllOwnedSessions()
    } catch {
      applicationTerminationRequested = false
      throw error
    }
  }

  public func resumeAfterApplicationTerminationFailure() {
    applicationTerminationRequested = false
  }

  public func removeNamespace(_ namespaceID: Namespace.ID) async throws {
    try await lock(namespaceID: namespaceID)
    try await launcher.purge(namespaceID: namespaceID)
  }

  public func isUnlocked(_ namespaceID: Namespace.ID) -> Bool {
    sessions[namespaceID] != nil
  }

  private func lockAllOwnedSessions() async throws {
    var failures: [Namespace.ID: String] = [:]
    let namespaceIDs = Set(sessions.keys)
      .union(pendingUnlocks.keys)
      .union(lockingNamespaces)
    for namespaceID in namespaceIDs {
      do {
        try await lock(namespaceID: namespaceID)
      } catch {
        failures[namespaceID] = error.localizedDescription
      }
    }
    guard failures.isEmpty else {
      throw NamespaceCredentialBrokerError.lockAllFailed(failures)
    }
  }
}

public enum NamespaceCredentialBrokerError: LocalizedError, Sendable {
  case unlockUnavailable
  case unlockInterrupted
  case lockInProgress
  case locked
  case lockAllFailed([Namespace.ID: String])

  public var errorDescription: String? {
    switch self {
    case .unlockUnavailable:
      "Namespace credentials cannot be unlocked while another security operation is running."
    case .unlockInterrupted:
      "Namespace unlock was interrupted because the credentials were locked."
    case .lockInProgress:
      "Namespace credentials are already being locked."
    case .locked:
      "Protected namespace credentials are locked."
    case .lockAllFailed(let failures):
      "Protected credentials could not be cleared for \(failures.count) namespace(s)."
    }
  }
}
