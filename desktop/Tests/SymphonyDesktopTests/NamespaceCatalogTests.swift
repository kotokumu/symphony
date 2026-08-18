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
}
