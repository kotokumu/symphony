import Foundation
import SymphonyDesktopCore

public actor FileNamespaceRepository: NamespaceRepository {
  private static let documentVersion = 1
  private static let metadataFilename = "namespaces.json"
  private static let namespacesDirectoryName = "Namespaces"
  private static let pendingDeletionsDirectoryName = "PendingDeletions"

  private let storageDirectory: URL
  private let fileManager: FileManager

  public init(storageDirectory: URL, fileManager: FileManager = .default) {
    self.storageDirectory = storageDirectory
    self.fileManager = fileManager
  }

  public init(fileManager: FileManager = .default) throws {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw NamespaceStorageError.applicationSupportUnavailable
    }

    storageDirectory = applicationSupport.appendingPathComponent("Symphony", isDirectory: true)
    self.fileManager = fileManager
  }

  public func load() throws -> NamespaceCatalog {
    guard fileManager.fileExists(atPath: metadataURL.path) else {
      let catalog = NamespaceCatalog()
      try reconcilePendingDeletions(with: catalog)
      return catalog
    }

    let data: Data
    do {
      data = try Data(contentsOf: metadataURL)
    } catch {
      throw NamespaceStorageError.unreadableData
    }

    let document: NamespaceDocument
    do {
      document = try JSONDecoder().decode(NamespaceDocument.self, from: data)
    } catch {
      throw NamespaceStorageError.unreadableData
    }

    guard document.version == Self.documentVersion else {
      throw NamespaceStorageError.unsupportedVersion(document.version)
    }

    let catalog: NamespaceCatalog
    do {
      let namespaces = try document.namespaces.map { record in
        Namespace(id: record.id, name: try NamespaceName(validating: record.name))
      }
      catalog = try NamespaceCatalog(
        validating: namespaces,
        selectedID: document.selectedID
      )
    } catch {
      throw NamespaceStorageError.unreadableData
    }

    try reconcilePendingDeletions(with: catalog)
    try validateDirectories(for: catalog)
    return catalog
  }

  public func create(_ namespace: Namespace, saving catalog: NamespaceCatalog) throws {
    let directory = directoryURL(for: namespace.id)
    guard !fileManager.fileExists(atPath: directory.path) else {
      throw NamespaceStorageError.directoryAlreadyExists(directory)
    }

    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw NamespaceStorageError.createDirectoryFailed
    }

    do {
      try save(catalog)
    } catch {
      do {
        try fileManager.removeItem(at: directory)
      } catch {
        throw NamespaceStorageError.createRollbackFailed(directory)
      }
      throw error
    }
  }

  public func save(_ catalog: NamespaceCatalog) throws {
    try validateDirectories(for: catalog)

    do {
      try fileManager.createDirectory(
        at: storageDirectory,
        withIntermediateDirectories: true
      )
      let document = NamespaceDocument(
        version: Self.documentVersion,
        namespaces: catalog.namespaces.map(NamespaceRecord.init),
        selectedID: catalog.selectedID
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(document).write(to: metadataURL, options: .atomic)
    } catch let error as NamespaceStorageError {
      throw error
    } catch {
      throw NamespaceStorageError.saveFailed
    }
  }

  public func delete(
    _ namespace: Namespace,
    saving catalog: NamespaceCatalog
  ) throws -> NamespaceDeletionOutcome {
    let directory = directoryURL(for: namespace.id)
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw NamespaceStorageError.missingDirectory(namespace.name.value)
    }

    let pendingDirectory = pendingDeletionURL(for: namespace.id)
    guard !fileManager.fileExists(atPath: pendingDirectory.path) else {
      throw NamespaceStorageError.pendingDeletionConflict(pendingDirectory)
    }

    do {
      try fileManager.createDirectory(
        at: pendingDeletionsDirectory,
        withIntermediateDirectories: true
      )
      try fileManager.moveItem(at: directory, to: pendingDirectory)
    } catch {
      throw NamespaceStorageError.deleteStagingFailed(directory)
    }

    do {
      try save(catalog)
    } catch {
      do {
        try fileManager.moveItem(at: pendingDirectory, to: directory)
      } catch {
        throw NamespaceStorageError.deleteRollbackFailed(pendingDirectory)
      }
      throw error
    }

    do {
      try fileManager.removeItem(at: pendingDirectory)
      removePendingDirectoryWhenEmpty()
      return .complete
    } catch {
      return .cleanupPending(
        NamespaceStorageError.cleanupPending(pendingDirectory).localizedDescription)
    }
  }

  public func directoryURL(for id: Namespace.ID) -> URL {
    storageDirectory
      .appendingPathComponent(Self.namespacesDirectoryName, isDirectory: true)
      .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  private var metadataURL: URL {
    storageDirectory.appendingPathComponent(Self.metadataFilename)
  }

  private var pendingDeletionsDirectory: URL {
    storageDirectory.appendingPathComponent(
      Self.pendingDeletionsDirectoryName,
      isDirectory: true
    )
  }

  private func pendingDeletionURL(for id: Namespace.ID) -> URL {
    pendingDeletionsDirectory.appendingPathComponent(
      id.uuidString.lowercased(),
      isDirectory: true
    )
  }

  private func validateDirectories(for catalog: NamespaceCatalog) throws {
    for namespace in catalog.namespaces {
      var isDirectory: ObjCBool = false
      let directory = directoryURL(for: namespace.id)
      guard
        fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw NamespaceStorageError.missingDirectory(namespace.name.value)
      }
    }
  }

  private func reconcilePendingDeletions(with catalog: NamespaceCatalog) throws {
    guard fileManager.fileExists(atPath: pendingDeletionsDirectory.path) else {
      return
    }

    let pendingDirectories: [URL]
    do {
      pendingDirectories = try fileManager.contentsOfDirectory(
        at: pendingDeletionsDirectory,
        includingPropertiesForKeys: nil
      )
    } catch {
      throw NamespaceStorageError.pendingDeletionCleanupFailed(pendingDeletionsDirectory)
    }

    for directory in pendingDirectories {
      guard let id = Namespace.ID(uuidString: directory.lastPathComponent) else {
        throw NamespaceStorageError.unrecognizedPendingDeletion(directory)
      }
      if catalog.namespaces.contains(where: { $0.id == id }) {
        throw NamespaceStorageError.pendingDeletionRequiresRestore(
          directory,
          directoryURL(for: id)
        )
      }

      do {
        try fileManager.removeItem(at: directory)
      } catch {
        throw NamespaceStorageError.pendingDeletionCleanupFailed(directory)
      }
    }

    removePendingDirectoryWhenEmpty()
  }

  private func removePendingDirectoryWhenEmpty() {
    guard
      let contents = try? fileManager.contentsOfDirectory(
        at: pendingDeletionsDirectory,
        includingPropertiesForKeys: nil
      ),
      contents.isEmpty
    else {
      return
    }
    try? fileManager.removeItem(at: pendingDeletionsDirectory)
  }
}

public enum NamespaceStorageError: LocalizedError, Sendable {
  case applicationSupportUnavailable
  case unreadableData
  case unsupportedVersion(Int)
  case missingDirectory(String)
  case directoryAlreadyExists(URL)
  case createDirectoryFailed
  case createRollbackFailed(URL)
  case saveFailed
  case deleteStagingFailed(URL)
  case deleteRollbackFailed(URL)
  case pendingDeletionConflict(URL)
  case unrecognizedPendingDeletion(URL)
  case pendingDeletionRequiresRestore(URL, URL)
  case cleanupPending(URL)
  case pendingDeletionCleanupFailed(URL)

  public var errorDescription: String? {
    switch self {
    case .applicationSupportUnavailable:
      "Application Support is unavailable. Check the macOS user account and try again."
    case .unreadableData:
      "Namespace data could not be read. The file was not changed."
    case .unsupportedVersion(let version):
      "Namespace data version \(version) is not supported. The file was not changed."
    case .missingDirectory(let name):
      "The local directory for namespace “\(name)” is missing. Restore it before retrying."
    case .directoryAlreadyExists(let directory):
      "A local directory already exists at \(directory.path). Move it before retrying."
    case .createDirectoryFailed:
      "The namespace directory could not be created. Check disk access and try again."
    case .createRollbackFailed(let directory):
      "The namespace was not saved, and its local directory remains at \(directory.path)."
    case .saveFailed:
      "Namespace changes could not be saved. Check disk space and permissions, then try again."
    case .deleteStagingFailed(let directory):
      "The namespace could not be deleted because its local directory at \(directory.path) could not be prepared."
    case .deleteRollbackFailed(let directory):
      "Namespace deletion was not saved, and its local directory must be restored from \(directory.path)."
    case .pendingDeletionConflict(let directory):
      "Namespace deletion cannot continue while pending data remains at \(directory.path)."
    case .unrecognizedPendingDeletion(let directory):
      "Unrecognized pending namespace data remains at \(directory.path). Move it before retrying."
    case .pendingDeletionRequiresRestore(let pending, let destination):
      "Namespace deletion was not saved. Restore \(pending.path) to \(destination.path) before retrying."
    case .cleanupPending(let directory):
      "The namespace was deleted, but its local directory remains at \(directory.path). Symphony will retry cleanup the next time it starts."
    case .pendingDeletionCleanupFailed(let directory):
      "Pending namespace data at \(directory.path) could not be removed. Check disk access, then try again."
    }
  }
}

private struct NamespaceDocument: Codable {
  let version: Int
  let namespaces: [NamespaceRecord]
  let selectedID: Namespace.ID?
}

private struct NamespaceRecord: Codable {
  let id: Namespace.ID
  let name: String

  init(namespace: Namespace) {
    id = namespace.id
    name = namespace.name.value
  }
}
