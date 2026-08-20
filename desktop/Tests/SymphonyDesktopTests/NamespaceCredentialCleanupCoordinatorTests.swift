import Foundation
import XCTest

@testable import SymphonyDesktopInfrastructure
@testable import SymphonyDesktopCore

final class NamespaceCredentialCleanupCoordinatorTests: XCTestCase {
  func testRepositoryRollbackUnstagesDeletionWithoutPurgingCredential() async throws {
    let namespaceID = UUID()
    let store = PendingCredentialCleanupStore(fileURL: try ledgerURL())
    let purge = RecordingCredentialPurge()
    let coordinator = NamespaceCredentialCleanupCoordinator(
      store: store,
      purge: { id in try await purge.call(id) }
    )
    try await coordinator.stageDeletion(namespaceID)

    let message = await coordinator.finishDeletion(namespaceID, committed: false)

    XCTAssertNil(message)
    let purgedNamespaceIDs = await purge.namespaceIDs
    let pendingNamespaceIDs = try await store.pendingNamespaceIDs()
    XCTAssertEqual(purgedNamespaceIDs, [])
    XCTAssertEqual(pendingNamespaceIDs, [])
  }

  func testCommittedDeletionRetainsMarkerUntilFailedPurgeCanBeRetried() async throws {
    let namespaceID = UUID()
    let store = PendingCredentialCleanupStore(fileURL: try ledgerURL())
    let purge = RecordingCredentialPurge(shouldFail: true)
    let coordinator = NamespaceCredentialCleanupCoordinator(
      store: store,
      purge: { id in try await purge.call(id) }
    )
    try await coordinator.stageDeletion(namespaceID)

    let message = await coordinator.finishDeletion(namespaceID, committed: true)

    XCTAssertTrue(message?.contains("will be retried") == true)
    let pendingAfterFailure = try await store.pendingNamespaceIDs()
    XCTAssertEqual(pendingAfterFailure, [namespaceID])

    await purge.allowSuccess()
    try await coordinator.reconcile(existingNamespaceIDs: [])

    let purgedNamespaceIDs = await purge.namespaceIDs
    let pendingAfterRetry = try await store.pendingNamespaceIDs()
    XCTAssertEqual(purgedNamespaceIDs, [namespaceID, namespaceID])
    XCTAssertEqual(pendingAfterRetry, [])
  }

  func testReconciliationNeverPurgesCredentialForSurvivingNamespace() async throws {
    let namespaceID = UUID()
    let store = PendingCredentialCleanupStore(fileURL: try ledgerURL())
    try await store.mark(namespaceID)
    let purge = RecordingCredentialPurge()
    let coordinator = NamespaceCredentialCleanupCoordinator(
      store: store,
      purge: { id in try await purge.call(id) }
    )

    try await coordinator.reconcile(existingNamespaceIDs: [namespaceID])

    let purgedNamespaceIDs = await purge.namespaceIDs
    let pendingNamespaceIDs = try await store.pendingNamespaceIDs()
    XCTAssertEqual(purgedNamespaceIDs, [])
    XCTAssertEqual(pendingNamespaceIDs, [])
  }

  func testLedgerContainsOnlyNamespaceIDsAndUsesOwnerOnlyPermissions() async throws {
    let fileURL = try ledgerURL()
    let namespaceID = UUID()
    let store = PendingCredentialCleanupStore(fileURL: fileURL)

    try await store.mark(namespaceID)

    let text = try String(contentsOf: fileURL, encoding: .utf8)
    XCTAssertTrue(text.contains(namespaceID.uuidString))
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testGitHubCleanupIsPersistedAndRetriedOnlyForDisconnectedNamespace() async throws {
    let store = PendingCredentialCleanupStore(fileURL: try ledgerURL())
    let failingPurge = RecordingCredentialPurge(shouldFail: true)
    let namespaceID = UUID()
    let coordinator = GitHubCredentialCleanupCoordinator(
      store: store,
      purge: { id in try await failingPurge.call(id) }
    )

    let warning = try await coordinator.cleanup(namespaceID)

    XCTAssertTrue(try XCTUnwrap(warning).contains("will be retried"))
    let pendingAfterFailure = try await store.pendingNamespaceIDs()
    XCTAssertEqual(pendingAfterFailure, [namespaceID])

    await failingPurge.allowSuccess()
    var disconnectedCatalog = NamespaceCatalog()
    try disconnectedCatalog.create(named: "Research", id: namespaceID)
    try await coordinator.reconcile(disconnectedCatalog)

    let purged = await failingPurge.namespaceIDs
    let pendingAfterRetry = try await store.pendingNamespaceIDs()
    XCTAssertEqual(purged, [namespaceID, namespaceID])
    XCTAssertTrue(pendingAfterRetry.isEmpty)
  }

  func testCommittedGitHubConnectionCancelsStaleCleanupWithoutPurgingCredential() async throws {
    let store = PendingCredentialCleanupStore(fileURL: try ledgerURL())
    let namespaceID = UUID()
    try await store.mark(namespaceID)
    var catalog = NamespaceCatalog()
    try catalog.create(named: "Research", id: namespaceID)
    let connection = try GitHubConnection(
      appID: 10,
      installationID: 20,
      accountLogin: "octo",
      repositoryID: 30,
      repositoryFullName: "octo/research",
      repositoryURL: URL(string: "https://github.com/octo/research")!
    )
    try catalog.connect(namespaceID, to: .github(connection))
    let purge = RecordingCredentialPurge()
    let coordinator = GitHubCredentialCleanupCoordinator(
      store: store,
      purge: { id in try await purge.call(id) }
    )

    try await coordinator.reconcile(catalog)

    let purged = await purge.namespaceIDs
    let pending = try await store.pendingNamespaceIDs()
    XCTAssertTrue(purged.isEmpty)
    XCTAssertTrue(pending.isEmpty)
  }

  private func ledgerURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NamespaceCredentialCleanupTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("pending.json")
  }
}

private actor RecordingCredentialPurge {
  private(set) var namespaceIDs: [UUID] = []
  private var shouldFail: Bool

  init(shouldFail: Bool = false) {
    self.shouldFail = shouldFail
  }

  func call(_ namespaceID: UUID) throws {
    namespaceIDs.append(namespaceID)
    if shouldFail {
      throw TestCredentialPurgeError.failed
    }
  }

  func allowSuccess() {
    shouldFail = false
  }
}

private enum TestCredentialPurgeError: LocalizedError {
  case failed

  var errorDescription: String? { "Purge failed." }
}
