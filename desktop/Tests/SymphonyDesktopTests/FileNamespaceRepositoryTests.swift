import Foundation
import XCTest

@testable import SymphonyDesktop
@testable import SymphonyDesktopCore
@testable import SymphonyDesktopInfrastructure

final class FileNamespaceRepositoryTests: XCTestCase {
  private var storageDirectory: URL!

  override func setUpWithError() throws {
    storageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: storageDirectory,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: storageDirectory)
    storageDirectory = nil
  }

  func testReturnsAnEmptyCatalogWhenNoMetadataExists() async throws {
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)

    let catalog = try await repository.load()

    XCTAssertTrue(catalog.namespaces.isEmpty)
    XCTAssertNil(catalog.selectedID)
  }

  func testPersistsNamespacesSelectionAndStableDirectories() async throws {
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let directory = repository.directoryURL(for: namespace.id)

    try await repository.create(namespace, saving: catalog)
    let reloaded = try await FileNamespaceRepository(storageDirectory: storageDirectory).load()

    XCTAssertEqual(reloaded, catalog)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertTrue(directory.lastPathComponent.contains(namespace.id.uuidString.lowercased()))
    XCTAssertFalse(directory.path.contains(namespace.name.value))
  }

  func testPersistsGitHubConnectionAndMigratesVersionOneMetadata() async throws {
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    try await repository.create(namespace, saving: catalog)
    let connection = try GitHubConnection(
      appID: 10,
      installationID: 20,
      accountLogin: "octo",
      repositoryID: 30,
      repositoryFullName: "octo/research",
      repositoryURL: URL(string: "https://github.com/octo/research")!
    )
    try catalog.connect(namespace.id, to: .github(connection))
    try await repository.save(catalog)

    let connected = try await repository.load()

    XCTAssertEqual(connected.selectedNamespace?.platformConnection, .github(connection))
    let metadataURL = storageDirectory.appendingPathComponent("namespaces.json")
    let metadata = try Data(contentsOf: metadataURL)
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: metadata) as? [String: Any]
    )
    XCTAssertEqual(Set(document.keys), ["namespaces", "selectedID", "version"])
    XCTAssertEqual((document["version"] as? NSNumber)?.intValue, 2)
    let records = try XCTUnwrap(document["namespaces"] as? [[String: Any]])
    let record = try XCTUnwrap(records.first)
    XCTAssertEqual(Set(record.keys), ["id", "name", "platformConnection"])
    let platform = try XCTUnwrap(record["platformConnection"] as? [String: Any])
    XCTAssertEqual(Set(platform.keys), ["github", "kind"])
    XCTAssertEqual(platform["kind"] as? String, "github")
    let github = try XCTUnwrap(platform["github"] as? [String: Any])
    XCTAssertEqual(
      Set(github.keys),
      [
        "accountLogin", "appID", "installationID", "repositoryFullName", "repositoryID",
        "repositoryURL",
      ]
    )
    XCTAssertEqual(github["repositoryFullName"] as? String, "octo/research")
    let oldNamespaceID = UUID()
    let oldDirectory = repository.directoryURL(for: oldNamespaceID)
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    try Data(
      """
      {"version":1,"namespaces":[{"id":"\(oldNamespaceID.uuidString)","name":"Legacy"}],"selectedID":"\(oldNamespaceID.uuidString)"}
      """.utf8
    ).write(to: metadataURL, options: .atomic)

    let migrated = try await repository.load()

    XCTAssertEqual(migrated.selectedNamespace?.name.value, "Legacy")
    XCTAssertNil(migrated.selectedNamespace?.platformConnection)
    try await repository.save(migrated)
    let rewritten = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
    )
    XCTAssertEqual((rewritten["version"] as? NSNumber)?.intValue, 2)
  }

  func testDoesNotOverwriteCorruptMetadata() async throws {
    let metadataURL = storageDirectory.appendingPathComponent("namespaces.json")
    let corruptData = Data("{not-json".utf8)
    try corruptData.write(to: metadataURL)
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)

    await assertThrowsErrorAsync(try await repository.load()) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace data could not be read. The file was not changed."
      )
    }
    XCTAssertEqual(try Data(contentsOf: metadataURL), corruptData)
  }

  func testDoesNotCleanPendingDataWhenMetadataIsUnreadable() async throws {
    let metadataURL = storageDirectory.appendingPathComponent("namespaces.json")
    try Data("{not-json".utf8).write(to: metadataURL)
    let pendingDirectory =
      storageDirectory
      .appendingPathComponent("PendingDeletions")
      .appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)

    await assertThrowsErrorAsync(try await repository.load()) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace data could not be read. The file was not changed."
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))
  }

  func testRejectsUnsupportedMetadataWithoutOverwritingIt() async throws {
    let metadataURL = storageDirectory.appendingPathComponent("namespaces.json")
    let unsupportedData = Data("{\"version\":3,\"namespaces\":[],\"selectedID\":null}".utf8)
    try unsupportedData.write(to: metadataURL)
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)

    await assertThrowsErrorAsync(try await repository.load()) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace data version 3 is not supported. The file was not changed."
      )
    }
    XCTAssertEqual(try Data(contentsOf: metadataURL), unsupportedData)
  }

  func testRejectsDuplicatePersistedIdentitiesWithoutOverwritingThem() async throws {
    let metadataURL = storageDirectory.appendingPathComponent("namespaces.json")
    let id = UUID()
    let duplicateData = Data(
      """
      {"version":1,"namespaces":[
        {"id":"\(id.uuidString)","name":"Research"},
        {"id":"\(id.uuidString)","name":"Operations"}
      ],"selectedID":"\(id.uuidString)"}
      """.utf8
    )
    try duplicateData.write(to: metadataURL)
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)

    await assertThrowsErrorAsync(try await repository.load()) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace data could not be read. The file was not changed."
      )
    }
    XCTAssertEqual(try Data(contentsOf: metadataURL), duplicateData)
  }

  func testReportsMissingNamespaceDirectoryWithoutRepairingIt() async throws {
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    try await repository.create(namespace, saving: catalog)
    let directory = repository.directoryURL(for: namespace.id)
    try FileManager.default.removeItem(at: directory)

    await assertThrowsErrorAsync(try await repository.load()) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "The local directory for namespace “Research” is missing. Restore it before retrying."
      )
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath:
          storageDirectory
          .appendingPathComponent("Namespaces")
          .appendingPathComponent(namespace.id.uuidString.lowercased())
          .path
      )
    )
  }

  func testCreationRemovesItsDirectoryWhenMetadataCannotBeSaved() async throws {
    let metadataURL = storageDirectory.appendingPathComponent("namespaces.json")
    try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let directory = repository.directoryURL(for: namespace.id)

    await assertThrowsErrorAsync(try await repository.create(namespace, saving: catalog)) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace changes could not be saved. Check disk space and permissions, then try again."
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testCreationReportsTheDirectoryWhenSaveAndRollbackBothFail() async throws {
    let metadataURL = storageDirectory.appendingPathComponent("namespaces.json")
    try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
    let fileManager = FailingNamespaceRemovalFileManager()
    let repository = FileNamespaceRepository(
      storageDirectory: storageDirectory,
      fileManager: fileManager
    )
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let directory = repository.directoryURL(for: namespace.id)

    await assertThrowsErrorAsync(try await repository.create(namespace, saving: catalog)) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "The namespace was not saved, and its local directory remains at \(directory.path)."
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
  }

  func testDeletionRestoresItsDirectoryWhenMetadataCannotBeSaved() async throws {
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    try await repository.create(namespace, saving: catalog)
    let directory = repository.directoryURL(for: namespace.id)
    let metadataURL = storageDirectory.appendingPathComponent("namespaces.json")
    try FileManager.default.removeItem(at: metadataURL)
    try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
    _ = try catalog.delete(namespace.id)

    await assertThrowsErrorAsync(try await repository.delete(namespace, saving: catalog)) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace changes could not be saved. Check disk space and permissions, then try again."
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath:
          storageDirectory
          .appendingPathComponent("PendingDeletions")
          .appendingPathComponent(namespace.id.uuidString.lowercased())
          .path
      )
    )
  }

  func testDeletionCanFinishPendingCleanupOnTheNextLoad() async throws {
    let fileManager = FailingPendingRemovalFileManager()
    let repository = FileNamespaceRepository(
      storageDirectory: storageDirectory,
      fileManager: fileManager
    )
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    try await repository.create(namespace, saving: catalog)
    _ = try catalog.delete(namespace.id)

    let outcome = try await repository.delete(namespace, saving: catalog)

    guard case .cleanupPending(let message) = outcome else {
      return XCTFail("Expected cleanup to remain pending")
    }
    XCTAssertTrue(message.contains("Symphony will retry cleanup"))

    let reloaded = try await FileNamespaceRepository(storageDirectory: storageDirectory).load()
    XCTAssertTrue(reloaded.namespaces.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: storageDirectory.appendingPathComponent("PendingDeletions").path
      )
    )
  }

  func testEmptyPendingContainerCleanupDoesNotBlockDeletionOrLoading() async throws {
    let fileManager = FailingPendingContainerRemovalFileManager()
    let repository = FileNamespaceRepository(
      storageDirectory: storageDirectory,
      fileManager: fileManager
    )
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    try await repository.create(namespace, saving: catalog)
    _ = try catalog.delete(namespace.id)

    let outcome = try await repository.delete(namespace, saving: catalog)
    let reloaded = try await repository.load()

    XCTAssertEqual(outcome, .complete)
    XCTAssertTrue(reloaded.namespaces.isEmpty)
  }

  func testLoadPreservesPendingDataWhenDeletionWasNotCommitted() async throws {
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    try await repository.create(namespace, saving: catalog)
    let directory = repository.directoryURL(for: namespace.id)
    let pendingDirectory =
      storageDirectory
      .appendingPathComponent("PendingDeletions")
      .appendingPathComponent(namespace.id.uuidString.lowercased())
    try FileManager.default.createDirectory(
      at: pendingDirectory.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.moveItem(at: directory, to: pendingDirectory)

    await assertThrowsErrorAsync(try await repository.load()) { error in
      XCTAssertTrue(
        error.localizedDescription.hasPrefix("Namespace deletion was not saved. Restore "))
      XCTAssertTrue(
        error.localizedDescription.contains(
          "PendingDeletions/\(namespace.id.uuidString.lowercased()) to "
        )
      )
      XCTAssertTrue(
        error.localizedDescription.contains(
          "Namespaces/\(namespace.id.uuidString.lowercased()) before retrying."
        )
      )
      XCTAssertTrue(error.localizedDescription.hasSuffix("before retrying."))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testLoadPreservesDataAfterDeleteSaveAndRollbackBothFail() async throws {
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    try await repository.create(namespace, saving: catalog)
    let directory = repository.directoryURL(for: namespace.id)
    let pendingDirectory =
      storageDirectory
      .appendingPathComponent("PendingDeletions")
      .appendingPathComponent(namespace.id.uuidString.lowercased())
    _ = try catalog.delete(namespace.id)
    let failingRepository = FileNamespaceRepository(
      storageDirectory: storageDirectory,
      fileManager: FailingDeleteSaveAndRollbackFileManager(storageDirectory: storageDirectory)
    )

    await assertThrowsErrorAsync(
      try await failingRepository.delete(namespace, saving: catalog)
    ) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace deletion was not saved, and its local directory must be restored from \(pendingDirectory.path)."
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))

    await assertThrowsErrorAsync(
      try await FileNamespaceRepository(storageDirectory: storageDirectory).load()
    ) { error in
      XCTAssertTrue(
        error.localizedDescription.hasPrefix("Namespace deletion was not saved. Restore "))
      XCTAssertTrue(
        error.localizedDescription.contains(
          "PendingDeletions/\(namespace.id.uuidString.lowercased()) to "
        )
      )
      XCTAssertTrue(
        error.localizedDescription.contains(
          "Namespaces/\(namespace.id.uuidString.lowercased()) before retrying."
        )
      )
      XCTAssertTrue(error.localizedDescription.hasSuffix("before retrying."))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))
  }

  @MainActor
  func testControllerOperationsSurviveRepositoryAndControllerRecreation() async throws {
    let firstRepository = FileNamespaceRepository(storageDirectory: storageDirectory)
    let firstController = NamespaceController(repository: firstRepository)
    await firstController.load()
    try await firstController.createNamespace(named: "Research")
    let researchID = try XCTUnwrap(firstController.catalog.selectedID)
    try await firstController.createNamespace(named: "Operations")
    let operationsID = try XCTUnwrap(firstController.catalog.selectedID)
    let connection = try GitHubConnection(
      appID: 10,
      installationID: 20,
      accountLogin: "octo",
      repositoryID: 30,
      repositoryFullName: "octo/research",
      repositoryURL: URL(string: "https://github.com/octo/research")!
    )
    try await firstController.connectNamespace(researchID, to: connection)
    try await firstController.renameNamespace(researchID, to: "Market Research")
    try await firstController.selectNamespace(researchID)

    let restoredController = NamespaceController(
      repository: FileNamespaceRepository(storageDirectory: storageDirectory)
    )
    await restoredController.load()

    let restoredCatalog = restoredController.catalog
    XCTAssertEqual(restoredCatalog.namespaces.map(\.name.value), ["Market Research", "Operations"])
    XCTAssertEqual(restoredCatalog.selectedID, researchID)
    XCTAssertEqual(
      restoredCatalog.namespaces.first(where: { $0.id == researchID })?.platformConnection,
      .github(connection)
    )

    _ = try await restoredController.deleteNamespace(operationsID)
    let finalController = NamespaceController(
      repository: FileNamespaceRepository(storageDirectory: storageDirectory)
    )
    await finalController.load()

    let finalCatalog = finalController.catalog
    XCTAssertEqual(finalCatalog.namespaces.map(\.name.value), ["Market Research"])
    XCTAssertEqual(finalCatalog.selectedID, researchID)
    XCTAssertEqual(finalCatalog.selectedNamespace?.platformConnection, .github(connection))
  }
}

private final class FailingPendingRemovalFileManager: FileManager, @unchecked Sendable {
  override func removeItem(at URL: URL) throws {
    if URL.path.contains("PendingDeletions") && URL.lastPathComponent != "PendingDeletions" {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.removeItem(at: URL)
  }
}

private final class FailingNamespaceRemovalFileManager: FileManager, @unchecked Sendable {
  override func removeItem(at URL: URL) throws {
    if URL.path.contains("Namespaces") && URL.lastPathComponent != "Namespaces" {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.removeItem(at: URL)
  }
}

private final class FailingPendingContainerRemovalFileManager: FileManager, @unchecked Sendable {
  override func removeItem(at URL: URL) throws {
    if URL.lastPathComponent == "PendingDeletions" {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.removeItem(at: URL)
  }
}

private final class FailingDeleteSaveAndRollbackFileManager: FileManager, @unchecked Sendable {
  private let storageDirectory: URL

  init(storageDirectory: URL) {
    self.storageDirectory = storageDirectory
    super.init()
  }

  override func createDirectory(
    at url: URL,
    withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil
  ) throws {
    if url.standardizedFileURL == storageDirectory.standardizedFileURL {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.createDirectory(
      at: url,
      withIntermediateDirectories: createIntermediates,
      attributes: attributes
    )
  }

  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if srcURL.path.contains("PendingDeletions")
      && dstURL.path.contains("Namespaces")
    {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.moveItem(at: srcURL, to: dstURL)
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error to be thrown", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
