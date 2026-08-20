import Darwin
import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit

final class BrokerClientAuthorizerTests: XCTestCase {
  func testAuthorizesExpectedDesktopParentWithMatchingCodeRequirement() throws {
    let helper = URL(fileURLWithPath: "/Applications/Symphony.app/Contents/Helpers/SymphonyCredentialBroker")
    let desktop = URL(fileURLWithPath: "/Applications/Symphony.app/Contents/MacOS/SymphonyDesktop")
    let signatureChecker = RecordingBrokerCodeSignatureChecker(result: true)
    let authorizer = ParentCodeSignatureBrokerClientAuthorizer(
      processInspector: StubBrokerParentProcessInspector(
        processID: 42,
        executableURL: desktop
      ),
      codeSignatureChecker: signatureChecker,
      helperExecutableURL: helper
    )

    try authorizer.authorizeCaller()

    XCTAssertEqual(
      signatureChecker.checks,
      [
        .init(
          processID: 42,
          desktopIdentifier: ParentCodeSignatureBrokerClientAuthorizer.desktopSigningIdentifier,
          desktopExecutableURL: desktop,
          helperExecutableURL: helper,
          containingAppURL: URL(fileURLWithPath: "/Applications/Symphony.app")
        )
      ]
    )
  }

  func testRejectsCallerAtDifferentExecutablePathBeforeCodeCheck() {
    let helper = URL(fileURLWithPath: "/Applications/Symphony.app/Contents/Helpers/SymphonyCredentialBroker")
    let signatureChecker = RecordingBrokerCodeSignatureChecker(result: true)
    let authorizer = ParentCodeSignatureBrokerClientAuthorizer(
      processInspector: StubBrokerParentProcessInspector(
        processID: 42,
        executableURL: URL(fileURLWithPath: "/tmp/untrusted")
      ),
      codeSignatureChecker: signatureChecker,
      helperExecutableURL: helper
    )

    XCTAssertThrowsError(try authorizer.authorizeCaller()) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "The native credential broker rejected an untrusted caller."
      )
    }
    XCTAssertTrue(signatureChecker.checks.isEmpty)
  }

  func testRejectsExpectedPathWhenRunningCodeDoesNotMatchDesignatedRequirement() {
    let helper = URL(fileURLWithPath: "/Applications/Symphony.app/Contents/Helpers/SymphonyCredentialBroker")
    let desktop = URL(fileURLWithPath: "/Applications/Symphony.app/Contents/MacOS/SymphonyDesktop")
    let authorizer = ParentCodeSignatureBrokerClientAuthorizer(
      processInspector: StubBrokerParentProcessInspector(
        processID: 42,
        executableURL: desktop
      ),
      codeSignatureChecker: RecordingBrokerCodeSignatureChecker(result: false),
      helperExecutableURL: helper
    )

    XCTAssertThrowsError(try authorizer.authorizeCaller())
  }

  func testRejectsRelocatedHelperBeforeInspectingNeighborSignature() {
    let helper = URL(fileURLWithPath: "/tmp/SymphonyCredentialBroker")
    let desktop = URL(fileURLWithPath: "/tmp/SymphonyDesktop")
    let signatureChecker = RecordingBrokerCodeSignatureChecker(result: true)
    let authorizer = ParentCodeSignatureBrokerClientAuthorizer(
      processInspector: StubBrokerParentProcessInspector(
        processID: 42,
        executableURL: desktop
      ),
      codeSignatureChecker: signatureChecker,
      helperExecutableURL: helper
    )

    XCTAssertThrowsError(try authorizer.authorizeCaller())
    XCTAssertTrue(signatureChecker.checks.isEmpty)
  }
}

private struct StubBrokerParentProcessInspector: BrokerParentProcessInspecting {
  let processID: pid_t
  let executableURL: URL

  func parentProcessID() -> pid_t { processID }
  func executableURL(for processID: pid_t) throws -> URL { executableURL }
}

private final class RecordingBrokerCodeSignatureChecker: BrokerCodeSignatureChecking,
  @unchecked Sendable
{
  struct Check: Equatable {
    let processID: pid_t
    let desktopIdentifier: String
    let desktopExecutableURL: URL
    let helperExecutableURL: URL
    let containingAppURL: URL
  }

  private let result: Bool
  private(set) var checks: [Check] = []

  init(result: Bool) {
    self.result = result
  }

  func process(
    _ processID: pid_t,
    satisfiesDesktopIdentifier desktopIdentifier: String,
    desktopExecutableURL: URL,
    helperExecutableURL: URL,
    containingAppURL: URL
  ) throws -> Bool {
    checks.append(
      .init(
        processID: processID,
        desktopIdentifier: desktopIdentifier,
        desktopExecutableURL: desktopExecutableURL,
        helperExecutableURL: helperExecutableURL,
        containingAppURL: containingAppURL
      )
    )
    return result
  }
}
