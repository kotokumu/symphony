import Foundation
import SymphonyDesktopCore

public actor PendingCredentialCleanupStore {
  private struct Document: Codable {
    let namespaceIDs: Set<Namespace.ID>
  }

  private let fileURL: URL
  private let fileManager: FileManager

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public init(fileManager: FileManager = .default) throws {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw PendingCredentialCleanupError.storageUnavailable
    }
    fileURL = applicationSupport
      .appendingPathComponent("Symphony", isDirectory: true)
      .appendingPathComponent("pending-credential-cleanup.json")
    self.fileManager = fileManager
  }

  public func pendingNamespaceIDs() throws -> Set<Namespace.ID> {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return []
    }
    do {
      return try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL)).namespaceIDs
    } catch {
      throw PendingCredentialCleanupError.unreadableLedger
    }
  }

  public func mark(_ namespaceID: Namespace.ID) throws {
    var pending = try pendingNamespaceIDs()
    pending.insert(namespaceID)
    try save(pending)
  }

  public func unmark(_ namespaceID: Namespace.ID) throws {
    var pending = try pendingNamespaceIDs()
    pending.remove(namespaceID)
    try save(pending)
  }

  private func save(_ pending: Set<Namespace.ID>) throws {
    do {
      if pending.isEmpty {
        if fileManager.fileExists(atPath: fileURL.path) {
          try fileManager.removeItem(at: fileURL)
        }
        return
      }
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(Document(namespaceIDs: pending)).write(to: fileURL, options: .atomic)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch let error as PendingCredentialCleanupError {
      throw error
    } catch {
      throw PendingCredentialCleanupError.saveFailed
    }
  }
}

public actor NamespaceCredentialCleanupCoordinator {
  public typealias Purge = @Sendable (Namespace.ID) async throws -> Void

  private let store: PendingCredentialCleanupStore
  private let purge: Purge

  public init(store: PendingCredentialCleanupStore, purge: @escaping Purge) {
    self.store = store
    self.purge = purge
  }

  public func reconcile(existingNamespaceIDs: Set<Namespace.ID>) async throws {
    var failures: [Namespace.ID: String] = [:]
    for namespaceID in try await store.pendingNamespaceIDs() {
      do {
        if !existingNamespaceIDs.contains(namespaceID) {
          try await purge(namespaceID)
        }
        try await store.unmark(namespaceID)
      } catch {
        failures[namespaceID] = error.localizedDescription
      }
    }
    guard failures.isEmpty else {
      throw PendingCredentialCleanupError.cleanupFailed(failures)
    }
  }

  public func stageDeletion(_ namespaceID: Namespace.ID) async throws {
    try await store.mark(namespaceID)
  }

  public func finishDeletion(
    _ namespaceID: Namespace.ID,
    committed: Bool
  ) async -> String? {
    do {
      if committed {
        try await purge(namespaceID)
      }
      try await store.unmark(namespaceID)
      return nil
    } catch {
      return committed
        ? "Protected credential cleanup is pending and will be retried: \(error.localizedDescription)"
        : "The credential cleanup marker could not be cleared: \(error.localizedDescription)"
    }
  }
}

public enum PendingCredentialCleanupError: LocalizedError, Sendable {
  case storageUnavailable
  case unreadableLedger
  case saveFailed
  case cleanupFailed([Namespace.ID: String])

  public var errorDescription: String? {
    switch self {
    case .storageUnavailable:
      "Credential cleanup storage is unavailable."
    case .unreadableLedger:
      "The credential cleanup ledger is unreadable."
    case .saveFailed:
      "The credential cleanup ledger could not be saved."
    case .cleanupFailed(let failures):
      "Protected credential cleanup failed for \(failures.count) namespace(s). Try again."
    }
  }
}
