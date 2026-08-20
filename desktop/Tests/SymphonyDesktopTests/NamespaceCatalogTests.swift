import Foundation
import XCTest

@testable import SymphonyDesktopCore

final class NamespaceCatalogTests: XCTestCase {
  func testCreatesNamespacesWithStableIdentityAndSelectsTheNewest() throws {
    var catalog = NamespaceCatalog()
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let first = try catalog.create(named: "Research", id: firstID)
    let second = try catalog.create(named: "Execution", id: secondID)

    XCTAssertEqual(first.id, firstID)
    XCTAssertEqual(second.id, secondID)
    XCTAssertEqual(catalog.namespaces.map(\.name.value), ["Research", "Execution"])
    XCTAssertEqual(catalog.selectedID, secondID)
  }

  func testRejectsCaseInsensitiveDuplicateNames() throws {
    var catalog = NamespaceCatalog()
    try catalog.create(named: "Research")

    XCTAssertThrowsError(try catalog.create(named: "research")) { error in
      XCTAssertEqual(error.localizedDescription, "A namespace named “research” already exists.")
    }
  }

  func testRejectsUnicodeCaseFoldedAndCanonicallyEquivalentNames() throws {
    var catalog = NamespaceCatalog()
    try catalog.create(named: "Straße")

    XCTAssertThrowsError(try catalog.create(named: "STRASSE"))

    var unicodeCatalog = NamespaceCatalog()
    try unicodeCatalog.create(named: "Café")

    XCTAssertThrowsError(try unicodeCatalog.create(named: "Cafe\u{301}"))
  }

  func testRejectsDuplicateStableIdentities() throws {
    let id = UUID()
    var catalog = NamespaceCatalog()
    try catalog.create(named: "Research", id: id)

    XCTAssertThrowsError(try catalog.create(named: "Operations", id: id)) { error in
      XCTAssertEqual(error.localizedDescription, "A namespace with this identity already exists.")
    }

    let namespaces = [
      Namespace(id: id, name: try NamespaceName(validating: "Research")),
      Namespace(id: id, name: try NamespaceName(validating: "Operations")),
    ]
    XCTAssertThrowsError(try NamespaceCatalog(validating: namespaces, selectedID: id)) { error in
      XCTAssertEqual(error.localizedDescription, "A namespace with this identity already exists.")
    }
  }

  func testRenamePreservesIdentityAndSelection() throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")

    try catalog.rename(namespace.id, to: "Trading Research")

    XCTAssertEqual(catalog.namespaces.first?.id, namespace.id)
    XCTAssertEqual(catalog.namespaces.first?.name.value, "Trading Research")
    XCTAssertEqual(catalog.selectedID, namespace.id)
  }

  func testDeletingTheSelectionChoosesItsNearestRemainingNeighbor() throws {
    var catalog = NamespaceCatalog()
    let first = try catalog.create(named: "First")
    let second = try catalog.create(named: "Second")
    let third = try catalog.create(named: "Third")
    try catalog.select(second.id)

    let deleted = try catalog.delete(second.id)

    XCTAssertEqual(deleted.id, second.id)
    XCTAssertEqual(catalog.namespaces.map(\.id), [first.id, third.id])
    XCTAssertEqual(catalog.selectedID, third.id)
  }

  func testDeletingTheLastNamespaceReturnsToTheEmptyState() throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Only")

    try catalog.delete(namespace.id)

    XCTAssertTrue(catalog.namespaces.isEmpty)
    XCTAssertNil(catalog.selectedID)
  }

  func testDeletionSelectionBehaviorAtCatalogBoundaries() throws {
    var catalog = NamespaceCatalog()
    let first = try catalog.create(named: "First")
    let second = try catalog.create(named: "Second")
    let third = try catalog.create(named: "Third")

    try catalog.select(first.id)
    try catalog.delete(first.id)
    XCTAssertEqual(catalog.selectedID, second.id)

    try catalog.delete(third.id)
    XCTAssertEqual(catalog.selectedID, second.id)
  }

  func testRenamingToAConflictingNamePreservesTheNamespace() throws {
    var catalog = NamespaceCatalog()
    let first = try catalog.create(named: "Research")
    try catalog.create(named: "Operations")

    XCTAssertThrowsError(try catalog.rename(first.id, to: "operations"))
    XCTAssertEqual(catalog.namespaces.first?.name.value, "Research")
  }

  func testRejectsPersistedSelectionThatDoesNotExist() throws {
    let namespace = Namespace(
      id: UUID(),
      name: try NamespaceName(validating: "Research")
    )

    XCTAssertThrowsError(
      try NamespaceCatalog(validating: [namespace], selectedID: UUID())
    ) { error in
      XCTAssertEqual(error.localizedDescription, "The selected namespace no longer exists.")
    }
  }

  func testNamespaceAcceptsExactlyOnePlatformConnectionUntilDisconnected() throws {
    var catalog = NamespaceCatalog()
    let namespace = try catalog.create(named: "Research")
    let connection = try githubConnection(repositoryID: 30, fullName: "octo/research")

    try catalog.connect(namespace.id, to: .github(connection))

    XCTAssertEqual(catalog.selectedNamespace?.platformConnection, .github(connection))
    XCTAssertThrowsError(
      try catalog.connect(
        namespace.id,
        to: .github(try githubConnection(repositoryID: 31, fullName: "octo/other"))
      )
    ) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "This namespace already has a platform connection. Disconnect it before connecting another platform."
      )
    }

    XCTAssertEqual(try catalog.disconnectPlatform(namespace.id), .github(connection))
    XCTAssertNil(catalog.selectedNamespace?.platformConnection)
  }

  private func githubConnection(repositoryID: Int64, fullName: String) throws -> GitHubConnection {
    try GitHubConnection(
      appID: 10,
      installationID: 20,
      accountLogin: "octo",
      repositoryID: repositoryID,
      repositoryFullName: fullName,
      repositoryURL: URL(string: "https://github.com/\(fullName)")!
    )
  }
}
