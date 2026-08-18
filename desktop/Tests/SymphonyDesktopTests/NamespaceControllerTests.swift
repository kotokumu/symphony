import Foundation
import XCTest

@testable import SymphonyDesktop
@testable import SymphonyDesktopCore

@MainActor
final class NamespaceControllerTests: XCTestCase {
  func testLoadsThePersistedCatalog() async throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let repository = TestNamespaceRepository(catalog: catalog)
    let controller = NamespaceController(repository: repository)

    await controller.load()

    XCTAssertEqual(controller.loadState, .ready)
    XCTAssertEqual(controller.catalog.selectedID, namespace.id)
  }

  func testReportsLoadFailureAndCanRetry() async throws {
    let repository = TestNamespaceRepository(catalog: NamespaceCatalog())
    await repository.failNextLoad()
    let controller = NamespaceController(repository: repository)

    await controller.load()

    XCTAssertEqual(controller.loadState, .failed("Test repository failure."))

    await controller.load()

    XCTAssertEqual(controller.loadState, .ready)
  }

  func testCreatesAReservedNamespaceBeforePublishingIt() async throws {
    let repository = TestNamespaceRepository(catalog: NamespaceCatalog())
    let controller = NamespaceController(repository: repository)
    await controller.load()

    try await controller.createNamespace(named: "Research")

    let snapshot = await repository.snapshot()
    let namespace = try XCTUnwrap(controller.catalog.selectedNamespace)
    XCTAssertEqual(namespace.name.value, "Research")
    XCTAssertEqual(snapshot.catalog, controller.catalog)
    XCTAssertEqual(snapshot.reservedIDs, [namespace.id])
  }

  func testRollsBackAReservedDirectoryWhenCreateCannotBeSaved() async throws {
    let repository = TestNamespaceRepository(catalog: NamespaceCatalog())
    let controller = NamespaceController(repository: repository)
    await controller.load()
    await repository.failNextSave()

    await assertThrowsErrorAsync(try await controller.createNamespace(named: "Research"))

    let snapshot = await repository.snapshot()
    XCTAssertTrue(controller.catalog.namespaces.isEmpty)
    XCTAssertEqual(snapshot.removedIDs, snapshot.reservedIDs)
  }

  func testRenamesAndSelectsOnlyAfterSaving() async throws {
    var catalog = NamespaceCatalog()
    let first = try catalog.create(named: "Research")
    let second = try catalog.create(named: "Operations")
    let repository = TestNamespaceRepository(catalog: catalog)
    let controller = NamespaceController(repository: repository)
    await controller.load()

    try await controller.renameNamespace(first.id, to: "Market Research")
    try await controller.selectNamespace(first.id)

    let snapshot = await repository.snapshot()
    XCTAssertEqual(controller.catalog.selectedID, first.id)
    XCTAssertEqual(controller.catalog.namespaces.first?.name.value, "Market Research")
    XCTAssertEqual(snapshot.catalog, controller.catalog)
    XCTAssertNotEqual(controller.catalog.selectedID, second.id)
  }

  func testDeletesMetadataBeforeRemovingTheNamespaceDirectory() async throws {
    var catalog = NamespaceCatalog()
    let first = try catalog.create(named: "Research")
    let second = try catalog.create(named: "Operations")
    let repository = TestNamespaceRepository(catalog: catalog)
    let controller = NamespaceController(repository: repository)
    await controller.load()

    try await controller.deleteNamespace(second.id)

    let snapshot = await repository.snapshot()
    XCTAssertEqual(controller.catalog.selectedID, first.id)
    XCTAssertEqual(snapshot.catalog, controller.catalog)
    XCTAssertEqual(snapshot.removedIDs, [second.id])
    XCTAssertEqual(snapshot.operations.suffix(2), ["save", "remove"])
  }
}

private actor TestNamespaceRepository: NamespaceRepository {
  struct Snapshot: Sendable {
    let catalog: NamespaceCatalog
    let reservedIDs: [Namespace.ID]
    let removedIDs: [Namespace.ID]
    let operations: [String]
  }

  private var catalog: NamespaceCatalog
  private var reservedIDs: [Namespace.ID] = []
  private var removedIDs: [Namespace.ID] = []
  private var operations: [String] = []
  private var shouldFailLoad = false
  private var shouldFailSave = false

  init(catalog: NamespaceCatalog) {
    self.catalog = catalog
  }

  func load() throws -> NamespaceCatalog {
    operations.append("load")
    if shouldFailLoad {
      shouldFailLoad = false
      throw TestRepositoryError.failure
    }
    return catalog
  }

  func save(_ catalog: NamespaceCatalog) throws {
    operations.append("save")
    if shouldFailSave {
      shouldFailSave = false
      throw TestRepositoryError.failure
    }
    self.catalog = catalog
  }

  func reserveDirectory(for id: Namespace.ID) -> URL {
    operations.append("reserve")
    reservedIDs.append(id)
    return URL(fileURLWithPath: "/tmp/\(id.uuidString)", isDirectory: true)
  }

  func removeDirectory(for id: Namespace.ID) {
    operations.append("remove")
    removedIDs.append(id)
  }

  func directoryURL(for id: Namespace.ID) -> URL {
    URL(fileURLWithPath: "/tmp/\(id.uuidString)", isDirectory: true)
  }

  func failNextLoad() {
    shouldFailLoad = true
  }

  func failNextSave() {
    shouldFailSave = true
  }

  func snapshot() -> Snapshot {
    Snapshot(
      catalog: catalog,
      reservedIDs: reservedIDs,
      removedIDs: removedIDs,
      operations: operations
    )
  }
}

private enum TestRepositoryError: LocalizedError {
  case failure

  var errorDescription: String? {
    "Test repository failure."
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error to be thrown", file: file, line: line)
  } catch {
    // The throwing behavior is the assertion.
  }
}
