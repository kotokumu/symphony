import XCTest

@testable import SymphonyDesktop
@testable import SymphonyDesktopCore

final class CredentialLockPresentationTests: XCTestCase {
  func testPresentsEveryLockStateWithTheMatchingRecoveryAction() {
    let locked = CredentialLockPresentation(state: .locked())
    XCTAssertEqual(locked.status, "Namespace locked")
    XCTAssertNil(locked.detail)
    XCTAssertEqual(locked.systemImage, "lock.fill")
    XCTAssertFalse(locked.showsProgress)
    XCTAssertEqual(locked.tone, .secondary)
    XCTAssertEqual(locked.action, .unlock("Unlock"))
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
