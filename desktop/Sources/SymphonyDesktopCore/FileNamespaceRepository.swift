import Foundation

public actor FileNamespaceRepository: NamespaceRepository {
  private static let documentVersion = 1
  private static let metadataFilename = "namespaces.json"
  private static let namespacesDirectoryName = "Namespaces"

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
    let metadataURL = metadataURL

    guard fileManager.fileExists(atPath: metadataURL.path) else {
      return NamespaceCatalog()
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
      catalog = try NamespaceCatalog(
        validating: document.namespaces,
        selectedID: document.selectedID
      )
    } catch {
      throw NamespaceStorageError.unreadableData
    }

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

    return catalog
  }

  public func save(_ catalog: NamespaceCatalog) throws {
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

    do {
      try fileManager.createDirectory(
        at: storageDirectory,
        withIntermediateDirectories: true
      )
      let document = NamespaceDocument(
        version: Self.documentVersion,
        namespaces: catalog.namespaces,
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

  public func reserveDirectory(for id: Namespace.ID) throws -> URL {
    let directory = directoryURL(for: id)

    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    } catch {
      throw NamespaceStorageError.createDirectoryFailed
    }
  }

  public func removeDirectory(for id: Namespace.ID) throws {
    let directory = directoryURL(for: id)

    guard fileManager.fileExists(atPath: directory.path) else {
      return
    }

    do {
      try fileManager.removeItem(at: directory)
    } catch {
      throw NamespaceStorageError.removeDirectoryFailed(directory)
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
}

public enum NamespaceStorageError: LocalizedError, Sendable {
  case applicationSupportUnavailable
  case unreadableData
  case unsupportedVersion(Int)
  case missingDirectory(String)
  case createDirectoryFailed
  case saveFailed
  case removeDirectoryFailed(URL)

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
    case .createDirectoryFailed:
      "The namespace directory could not be created. Check disk access and try again."
    case .saveFailed:
      "Namespace changes could not be saved. Check disk space and permissions, then try again."
    case .removeDirectoryFailed(let directory):
      "The namespace was deleted, but its local directory remains at \(directory.path)."
    }
  }
}

private struct NamespaceDocument: Codable {
  let version: Int
  let namespaces: [Namespace]
  let selectedID: Namespace.ID?
}
