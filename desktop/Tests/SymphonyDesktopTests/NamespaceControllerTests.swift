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
    XCTAssertEqual(snapshot.createdIDs, [namespace.id])
  }

  func testDoesNotPublishCreationWhenTheRepositoryRejectsIt() async throws {
    let repository = TestNamespaceRepository(catalog: NamespaceCatalog())
    let controller = NamespaceController(repository: repository)
    await controller.load()
    await repository.failNextCreate()

    do {
      try await controller.createNamespace(named: "Research")
      XCTFail("Expected an error to be thrown")
    } catch {
      // The throwing behavior is the assertion.
    }

    let snapshot = await repository.snapshot()
    XCTAssertTrue(controller.catalog.namespaces.isEmpty)
    XCTAssertFalse(controller.isChanging)
    XCTAssertTrue(snapshot.createdIDs.isEmpty)
    XCTAssertTrue(snapshot.catalog.namespaces.isEmpty)
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

  func testRenameSaveFailurePreservesPublishedAndPersistedState() async throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let repository = TestNamespaceRepository(catalog: catalog)
    let controller = NamespaceController(repository: repository)
    await controller.load()
    await repository.failNextSave()

    do {
      try await controller.renameNamespace(namespace.id, to: "Market Research")
      XCTFail("Expected an error to be thrown")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Test repository failure.")
    }

    let snapshot = await repository.snapshot()
    XCTAssertEqual(controller.catalog, catalog)
    XCTAssertEqual(snapshot.catalog, catalog)
    XCTAssertFalse(controller.isChanging)
  }

  func testSelectionSaveFailurePreservesPublishedAndPersistedState() async throws {
    var catalog = NamespaceCatalog()
    let first = try catalog.create(named: "Research")
    let second = try catalog.create(named: "Operations")
    let repository = TestNamespaceRepository(catalog: catalog)
    let controller = NamespaceController(repository: repository)
    await controller.load()
    await repository.failNextSave()

    do {
      try await controller.selectNamespace(first.id)
      XCTFail("Expected an error to be thrown")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Test repository failure.")
    }

    let snapshot = await repository.snapshot()
    XCTAssertEqual(controller.catalog.selectedID, second.id)
    XCTAssertEqual(snapshot.catalog.selectedID, second.id)
    XCTAssertFalse(controller.isChanging)
  }

  func testDeletesMetadataBeforeRemovingTheNamespaceDirectory() async throws {
    var catalog = NamespaceCatalog()
    let first = try catalog.create(named: "Research")
    let second = try catalog.create(named: "Operations")
    let repository = TestNamespaceRepository(catalog: catalog)
    let controller = NamespaceController(repository: repository)
    await controller.load()

    let outcome = try await controller.deleteNamespace(second.id)

    let snapshot = await repository.snapshot()
    XCTAssertEqual(outcome, .complete)
    XCTAssertEqual(controller.catalog.selectedID, first.id)
    XCTAssertEqual(snapshot.catalog, controller.catalog)
    XCTAssertEqual(snapshot.deletedIDs, [second.id])
  }

  func testStopsTheDaemonBeforeDeletingNamespaceData() async throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let repository = TestNamespaceRepository(catalog: catalog)
    let operations = OperationRecorder()
    let controller = NamespaceController(
      repository: repository,
      beforeDelete: { id in
        operations.append("stop:\(id.uuidString)")
      },
      afterDelete: { id, succeeded in
        operations.append("finish:\(id.uuidString):\(succeeded)")
      }
    )
    await repository.recordOperations(in: operations)
    await controller.load()

    _ = try await controller.deleteNamespace(namespace.id)

    let recorded = operations.values
    XCTAssertEqual(
      recorded.suffix(3),
      [
        "stop:\(namespace.id.uuidString)",
        "delete",
        "finish:\(namespace.id.uuidString):true",
      ]
    )
  }

  func testStopFailurePreventsDeletionAndPreservesTheCatalog() async throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let repository = TestNamespaceRepository(catalog: catalog)
    let controller = NamespaceController(
      repository: repository,
      beforeDelete: { _ in
        throw TestDaemonStopError.failure
      }
    )
    await controller.load()

    do {
      _ = try await controller.deleteNamespace(namespace.id)
      XCTFail("Expected daemon stop failure")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Test daemon stop failure.")
    }

    let snapshot = await repository.snapshot()
    XCTAssertEqual(controller.catalog, catalog)
    XCTAssertEqual(snapshot.catalog, catalog)
    XCTAssertTrue(snapshot.deletedIDs.isEmpty)
    XCTAssertFalse(controller.isChanging)
  }

  func testDeleteFailurePreservesPublishedAndPersistedState() async throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let repository = TestNamespaceRepository(catalog: catalog)
    let operations = OperationRecorder()
    let controller = NamespaceController(
      repository: repository,
      afterDelete: { id, succeeded in
        operations.append("finish:\(id.uuidString):\(succeeded)")
      }
    )
    await controller.load()
    await repository.failNextDelete()

    do {
      _ = try await controller.deleteNamespace(namespace.id)
      XCTFail("Expected an error to be thrown")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Test repository failure.")
    }

    let snapshot = await repository.snapshot()
    XCTAssertEqual(controller.catalog, catalog)
    XCTAssertEqual(snapshot.catalog, catalog)
    XCTAssertEqual(operations.values, ["finish:\(namespace.id.uuidString):false"])
    XCTAssertFalse(controller.isChanging)
  }

  func testPublishesCommittedDeletionWithCleanupWarning() async throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let repository = TestNamespaceRepository(catalog: catalog)
    await repository.setDeletionOutcome(.cleanupPending("Cleanup will be retried."))
    let controller = NamespaceController(repository: repository)
    await controller.load()

    let outcome = try await controller.deleteNamespace(namespace.id)

    XCTAssertEqual(outcome, .cleanupPending("Cleanup will be retried."))
    XCTAssertTrue(controller.catalog.namespaces.isEmpty)
    XCTAssertFalse(controller.isChanging)
  }

  func testCredentialCleanupFailureBecomesPostCommitCleanupWarning() async throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let repository = TestNamespaceRepository(catalog: catalog)
    let controller = NamespaceController(
      repository: repository,
      cleanupAfterDelete: { _, committed in
        committed ? "Protected credential cleanup is pending." : nil
      }
    )
    await controller.load()

    let outcome = try await controller.deleteNamespace(namespace.id)

    XCTAssertEqual(
      outcome,
      .cleanupPending("Protected credential cleanup is pending.")
    )
    XCTAssertTrue(controller.catalog.namespaces.isEmpty)
  }

  func testRepositoryDeleteFailureSignalsCredentialRollbackInsteadOfCommittedCleanup() async throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let repository = TestNamespaceRepository(catalog: catalog)
    let recorder = OperationRecorder()
    let controller = NamespaceController(
      repository: repository,
      cleanupAfterDelete: { _, committed in
        recorder.append("credential-cleanup:\(committed)")
        return nil
      }
    )
    await controller.load()
    await repository.failNextDelete()

    do {
      _ = try await controller.deleteNamespace(namespace.id)
      XCTFail("Expected repository deletion to fail")
    } catch {}

    XCTAssertEqual(recorder.values, ["credential-cleanup:false"])
    XCTAssertEqual(controller.catalog, catalog)
  }

  func testGitHubConnectionPublishesOnlyAfterRepositorySaveAndDisconnectsTransactionally() async throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let repository = TestNamespaceRepository(catalog: catalog)
    let controller = NamespaceController(repository: repository)
    await controller.load()
    let connection = try GitHubConnection(
      appID: 10,
      installationID: 20,
      accountLogin: "octo",
      repositoryID: 30,
      repositoryFullName: "octo/research",
      repositoryURL: URL(string: "https://github.com/octo/research")!
    )

    await repository.failNextSave()
    do {
      try await controller.connectNamespace(namespace.id, to: connection)
      XCTFail("Expected save failure")
    } catch {}
    XCTAssertNil(controller.catalog.selectedNamespace?.platformConnection)

    try await controller.connectNamespace(namespace.id, to: connection)
    XCTAssertEqual(controller.catalog.selectedNamespace?.platformConnection, .github(connection))
    try await controller.disconnectNamespacePlatform(namespace.id)
    XCTAssertNil(controller.catalog.selectedNamespace?.platformConnection)
  }
}

private actor TestNamespaceRepository: NamespaceRepository {
  struct Snapshot: Sendable {
    let catalog: NamespaceCatalog
    let createdIDs: [Namespace.ID]
    let deletedIDs: [Namespace.ID]
    let operations: [String]
  }

  private var catalog: NamespaceCatalog
  private var createdIDs: [Namespace.ID] = []
  private var deletedIDs: [Namespace.ID] = []
  private var operations: [String] = []
  private var shouldFailLoad = false
  private var shouldFailCreate = false
  private var shouldFailSave = false
  private var shouldFailDelete = false
  private var deletionOutcome = NamespaceDeletionOutcome.complete
  private var operationRecorder: OperationRecorder?

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

  func create(_ namespace: Namespace, saving catalog: NamespaceCatalog) throws {
    operations.append("create")
    if shouldFailCreate {
      shouldFailCreate = false
      throw TestRepositoryError.failure
    }
    self.catalog = catalog
    createdIDs.append(namespace.id)
  }

  func save(_ catalog: NamespaceCatalog) throws {
    operations.append("save")
    if shouldFailSave {
      shouldFailSave = false
      throw TestRepositoryError.failure
    }
    self.catalog = catalog
  }

  func delete(
    _ namespace: Namespace,
    saving catalog: NamespaceCatalog
  ) throws -> NamespaceDeletionOutcome {
    operations.append("delete")
    if let operationRecorder {
      operationRecorder.append("delete")
    }
    if shouldFailDelete {
      shouldFailDelete = false
      throw TestRepositoryError.failure
    }
    self.catalog = catalog
    deletedIDs.append(namespace.id)
    return deletionOutcome
  }

  func failNextLoad() {
    shouldFailLoad = true
  }

  func failNextSave() {
    shouldFailSave = true
  }

  func failNextCreate() {
    shouldFailCreate = true
  }

  func failNextDelete() {
    shouldFailDelete = true
  }

  func setDeletionOutcome(_ outcome: NamespaceDeletionOutcome) {
    deletionOutcome = outcome
  }

  func recordOperations(in recorder: OperationRecorder) {
    operationRecorder = recorder
  }

  func snapshot() -> Snapshot {
    Snapshot(
      catalog: catalog,
      createdIDs: createdIDs,
      deletedIDs: deletedIDs,
      operations: operations
    )
  }
}

private final class OperationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ value: String) {
    lock.withLock {
      storage.append(value)
    }
  }

  var values: [String] {
    lock.withLock { storage }
  }
}

private enum TestRepositoryError: LocalizedError {
  case failure

  var errorDescription: String? {
    "Test repository failure."
  }
}

private enum TestDaemonStopError: LocalizedError {
  case failure

  var errorDescription: String? {
    "Test daemon stop failure."
  }
}
