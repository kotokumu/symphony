import XCTest

@testable import SymphonyDesktop
@testable import SymphonyDesktopCore

final class CredentialLockPresentationTests: XCTestCase {
  func testPresentsEveryLockStateWithTheMatchingRecoveryAction() {
    XCTAssertEqual(
      CredentialLockPresentation(state: .locked()),
      CredentialLockPresentation(
        status: "Namespace locked",
        detail: nil,
        systemImage: "lock.fill",
        showsProgress: false,
        tone: .secondary,
        action: .unlock("Unlock")
      )
    )
    XCTAssertEqual(
      CredentialLockPresentation(state: .unlocking).action,
      .none
    )
    XCTAssertEqual(
      CredentialLockPresentation(state: .unlocked).action,
      .lock("Lock")
    )
    XCTAssertEqual(
      CredentialLockPresentation(state: .locked(message: "Denied")).action,
      .unlock("Try Unlock Again")
    )
    XCTAssertEqual(
      CredentialLockPresentation(state: .lockFailed(message: "Still running")).action,
      .lock("Try Lock Again")
    )
  }
}
