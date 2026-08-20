import Foundation
import SymphonyCredentialBrokerProtocol
import SymphonyDesktopCore

public actor NamespaceCredentialBroker {
  private struct PendingUnlock {
    let generation: UUID
    let task: Task<any NamespaceCredentialBrokerSessionHandle, Error>
  }

  private struct PendingLock {
    let generation: UUID
    let task: Task<Void, Error>
  }

  private let launcher: any CredentialBrokerSessionLaunching
  private var sessions: [Namespace.ID: any NamespaceCredentialBrokerSessionHandle] = [:]
  private var pendingUnlocks: [Namespace.ID: PendingUnlock] = [:]
  private var pendingLocks: [Namespace.ID: PendingLock] = [:]
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
      pendingLocks[namespaceID] == nil,
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
        pendingLocks[namespaceID] == nil,
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
    if let pending = pendingLocks[namespaceID] {
      try await pending.task.value
      return
    }
    let generation = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      try await self.performLock(namespaceID: namespaceID)
    }
    pendingLocks[namespaceID] = PendingLock(generation: generation, task: task)
    do {
      try await task.value
    } catch {
      if pendingLocks[namespaceID]?.generation == generation {
        pendingLocks.removeValue(forKey: namespaceID)
      }
      throw error
    }
    if pendingLocks[namespaceID]?.generation == generation {
      pendingLocks.removeValue(forKey: namespaceID)
    }
  }

  private func performLock(namespaceID: Namespace.ID) async throws {
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
    let session = try availableSession(namespaceID)
    return try await session.signChallenge(challenge)
  }

  public func configureGitHubApp(
    appID: Int64,
    privateKeyFileURL: URL,
    namespaceID: Namespace.ID
  ) async throws {
    let session = try availableSession(namespaceID)
    try await session.configureGitHubApp(appID: appID, privateKeyFileURL: privateKeyFileURL)
  }

  public func discoverGitHubInstallations(
    namespaceID: Namespace.ID
  ) async throws -> [GitHubInstallation] {
    let session = try availableSession(namespaceID)
    return try await session.listGitHubInstallations().map {
      GitHubInstallation(
        id: $0.id,
        accountLogin: $0.accountLogin,
        accountType: $0.accountType,
        permissions: $0.permissions,
        isSuspended: $0.isSuspended
      )
    }
  }

  public func discoverGitHubRepositories(
    installationID: Int64,
    namespaceID: Namespace.ID
  ) async throws -> [GitHubRepository] {
    let session = try availableSession(namespaceID)
    return try await session.listGitHubRepositories(installationID: installationID).map {
      GitHubRepository(
        id: $0.id,
        fullName: $0.fullName,
        htmlURL: $0.htmlURL,
        isPrivate: $0.isPrivate
      )
    }
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

  public func removeGitHubAppCredential(namespaceID: Namespace.ID) async throws {
    try await removeNamespace(namespaceID)
  }

  public func isUnlocked(_ namespaceID: Namespace.ID) -> Bool {
    sessions[namespaceID] != nil
  }

  private func lockAllOwnedSessions() async throws {
    var failures: [Namespace.ID: String] = [:]
    let namespaceIDs = Set(sessions.keys)
      .union(pendingUnlocks.keys)
      .union(pendingLocks.keys)
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

  private func availableSession(
    _ namespaceID: Namespace.ID
  ) throws -> any NamespaceCredentialBrokerSessionHandle {
    guard
      let session = sessions[namespaceID],
      pendingLocks[namespaceID] == nil,
      startSuspensionCount == 0,
      !applicationTerminationRequested
    else {
      throw NamespaceCredentialBrokerError.locked
    }
    return session
  }
}

public enum NamespaceCredentialBrokerError: LocalizedError, Sendable {
  case unlockUnavailable
  case unlockInterrupted
  case locked
  case lockAllFailed([Namespace.ID: String])

  public var errorDescription: String? {
    switch self {
    case .unlockUnavailable:
      "Namespace credentials cannot be unlocked while another security operation is running."
    case .unlockInterrupted:
      "Namespace unlock was interrupted because the credentials were locked."
    case .locked:
      "Protected namespace credentials are locked."
    case .lockAllFailed(let failures):
      "Protected credentials could not be cleared for \(failures.count) namespace(s)."
    }
  }
}
