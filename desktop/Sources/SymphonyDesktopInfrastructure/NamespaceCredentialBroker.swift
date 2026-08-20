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
        startSuspensionCount == 0,
        !applicationTerminationRequested
      else {
        try await session.lock()
        throw NamespaceCredentialBrokerError.unlockInterrupted
      }
      pendingUnlocks.removeValue(forKey: namespaceID)
      sessions[namespaceID] = session
    } catch {
      if pendingUnlocks[namespaceID]?.generation == generation {
        pendingUnlocks.removeValue(forKey: namespaceID)
      }
      throw error
    }
  }

  public func lock(namespaceID: Namespace.ID) async throws {
    if let pending = pendingUnlocks.removeValue(forKey: namespaceID) {
      pending.task.cancel()
      if let session = try? await pending.task.value {
        try await session.lock()
      }
    }
    guard let session = sessions[namespaceID] else {
      return
    }
    try await session.lock()
    sessions.removeValue(forKey: namespaceID)
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
    let namespaceIDs = Set(sessions.keys).union(pendingUnlocks.keys)
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
  case lockAllFailed([Namespace.ID: String])

  public var errorDescription: String? {
    switch self {
    case .unlockUnavailable:
      "Namespace credentials cannot be unlocked while another security operation is running."
    case .unlockInterrupted:
      "Namespace unlock was interrupted because the credentials were locked."
    case .lockAllFailed(let failures):
      "Protected credentials could not be cleared for \(failures.count) namespace(s)."
    }
  }
}
