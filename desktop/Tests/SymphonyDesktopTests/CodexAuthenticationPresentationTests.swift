import SymphonyDesktopCore
import XCTest

@testable import SymphonyDesktop

final class CodexAuthenticationPresentationTests: XCTestCase {
  func testEveryAuthenticationStateHasTheExpectedVisibleStatusAndRecoveryAction() {
    let cases: [(CodexAuthenticationState, CodexAuthenticationPresentation)] = [
      (
        .signedOut,
        CodexAuthenticationPresentation(state: .signedOut)
      ),
      (
        .authenticating,
        CodexAuthenticationPresentation(state: .authenticating)
      ),
      (
        .signedIn,
        CodexAuthenticationPresentation(state: .signedIn)
      ),
      (
        .expired(message: "Session expired"),
        CodexAuthenticationPresentation(state: .expired(message: "Session expired"))
      ),
      (
        .failed(message: "Network unavailable"),
        CodexAuthenticationPresentation(state: .failed(message: "Network unavailable"))
      ),
    ]

    XCTAssertEqual(cases[0].1.status, "Codex signed out")
    XCTAssertEqual(cases[0].1.action, .signIn(title: "Sign in with ChatGPT"))
    XCTAssertEqual(cases[1].1.status, "Waiting for ChatGPT sign-in…")
    XCTAssertTrue(cases[1].1.showsProgress)
    XCTAssertEqual(cases[1].1.action, .none)
    XCTAssertEqual(cases[2].1.status, "Codex signed in")
    XCTAssertEqual(cases[2].1.action, .signOut(title: "Sign Out"))
    XCTAssertEqual(cases[3].1.status, "Codex sign-in expired")
    XCTAssertEqual(cases[3].1.detail, "Session expired")
    XCTAssertEqual(cases[3].1.action, .signIn(title: "Try Sign In Again"))
    XCTAssertEqual(cases[4].1.status, "Codex authentication failed")
    XCTAssertEqual(cases[4].1.detail, "Network unavailable")
    XCTAssertEqual(cases[4].1.action, .signIn(title: "Try Sign In Again"))
  }
}
