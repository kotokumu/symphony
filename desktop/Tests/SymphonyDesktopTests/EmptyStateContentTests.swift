import XCTest

@testable import SymphonyDesktop

final class EmptyStateContentTests: XCTestCase {
  func testInitialShellExplainsThatNoNamespacesExist() {
    let content = EmptyStateContent.namespaces

    XCTAssertEqual(content.title, "No Namespaces")
    XCTAssertEqual(
      content.message,
      "Create a namespace to start orchestrating work with Symphony."
    )
  }
}
