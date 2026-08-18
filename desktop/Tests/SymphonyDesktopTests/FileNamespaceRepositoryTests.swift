import Foundation
import XCTest

@testable import SymphonyDesktopCore

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
    let directory = try await repository.reserveDirectory(for: namespace.id)

    try await repository.save(catalog)
    let reloaded = try await FileNamespaceRepository(storageDirectory: storageDirectory).load()

    XCTAssertEqual(reloaded, catalog)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertTrue(directory.lastPathComponent.contains(namespace.id.uuidString.lowercased()))
    XCTAssertFalse(directory.path.contains(namespace.name.value))
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

  func testRejectsUnsupportedMetadataWithoutOverwritingIt() async throws {
    let metadataURL = storageDirectory.appendingPathComponent("namespaces.json")
    let unsupportedData = Data("{\"version\":2,\"namespaces\":[],\"selectedID\":null}".utf8)
    try unsupportedData.write(to: metadataURL)
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)

    await assertThrowsErrorAsync(try await repository.load()) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace data version 2 is not supported. The file was not changed."
      )
    }
    XCTAssertEqual(try Data(contentsOf: metadataURL), unsupportedData)
  }

  func testReportsMissingNamespaceDirectoryWithoutRepairingIt() async throws {
    let repository = FileNamespaceRepository(storageDirectory: storageDirectory)
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    _ = try await repository.reserveDirectory(for: namespace.id)
    try await repository.save(catalog)
    try await repository.removeDirectory(for: namespace.id)

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
