import XCTest

@testable import SymphonyDesktop

final class EmptyStateContentTests: XCTestCase {
  func testNoNamespaceCopyExplainsHowToStart() {
    let content = EmptyStateContent.noNamespaces

    XCTAssertEqual(content.title, "No Namespaces")
    XCTAssertEqual(
      content.message,
      "Create a namespace to start orchestrating work with Symphony."
    )
  }
}
