import XCTest

@testable import SymphonyDesktopCore

final class NamespaceNameTests: XCTestCase {
  func testAcceptsAValidNameWithoutChangingIt() throws {
    let name = try NamespaceName(validating: "Trading Research")

    XCTAssertEqual(name.value, "Trading Research")
  }

  func testRejectsInvalidNamesWithActionableMessages() {
    assertInvalid("", message: "Enter a namespace name.")
    assertInvalid(" Research", message: "Remove spaces from the beginning or end of the name.")
    assertInvalid("Research\n", message: "Namespace names cannot contain control characters.")
    assertInvalid(String(repeating: "a", count: 65), message: "Use 64 characters or fewer.")
  }

  private func assertInvalid(_ value: String, message: String) {
    XCTAssertThrowsError(try NamespaceName(validating: value)) { error in
      XCTAssertEqual(error.localizedDescription, message)
    }
  }
}
