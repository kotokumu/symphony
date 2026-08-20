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
          containingAppURL: URL(
            fileURLWithPath: "/Applications/Symphony.app",
            isDirectory: true
          )
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

  func testSystemCheckerBuildsPinnedRequirementAndValidatesEveryCodeBoundary() throws {
    let helper = URL(fileURLWithPath: "/Applications/Symphony.app/Contents/Helpers/SymphonyCredentialBroker")
    let desktop = URL(fileURLWithPath: "/Applications/Symphony.app/Contents/MacOS/SymphonyDesktop")
    let application = URL(fileURLWithPath: "/Applications/Symphony.app")
    let security = RecordingBrokerSecurityValidator(
      teamIdentifier: "TEAM123456",
      staticResults: [true, true],
      processResult: true
    )
    let checker = SystemBrokerCodeSignatureChecker(security: security)

    let result = try checker.process(
      42,
      satisfiesDesktopIdentifier: "com.kotokumu.symphony.desktop",
      desktopExecutableURL: desktop,
      helperExecutableURL: helper,
      containingAppURL: application
    )

    let requirement =
      "anchor apple generic and identifier \"com.kotokumu.symphony.desktop\" and certificate leaf[subject.OU] = \"TEAM123456\""
    XCTAssertTrue(result)
    XCTAssertEqual(
      security.operations,
      [
        .team(helper),
        .staticCode(application, requirement: nil),
        .staticCode(desktop, requirement: requirement),
        .process(42, requirement: requirement),
      ]
    )
  }

  func testSystemCheckerStopsBeforeParentValidationWhenAppSealIsInvalid() throws {
    let security = RecordingBrokerSecurityValidator(
      teamIdentifier: "TEAM123456",
      staticResults: [false],
      processResult: true
    )
    let checker = SystemBrokerCodeSignatureChecker(security: security)

    let result = try checker.process(
      42,
      satisfiesDesktopIdentifier: "com.kotokumu.symphony.desktop",
      desktopExecutableURL: URL(fileURLWithPath: "/app/desktop"),
      helperExecutableURL: URL(fileURLWithPath: "/app/helper"),
      containingAppURL: URL(fileURLWithPath: "/app")
    )

    XCTAssertFalse(result)
    XCTAssertEqual(security.operations.count, 2)
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

private final class RecordingBrokerSecurityValidator: BrokerSecurityValidating,
  @unchecked Sendable
{
  enum Operation: Equatable {
    case team(URL)
    case staticCode(URL, requirement: String?)
    case process(pid_t, requirement: String)
  }

  private let teamIdentifier: String
  private var staticResults: [Bool]
  private let processResult: Bool
  private(set) var operations: [Operation] = []

  init(teamIdentifier: String, staticResults: [Bool], processResult: Bool) {
    self.teamIdentifier = teamIdentifier
    self.staticResults = staticResults
    self.processResult = processResult
  }

  func signingTeamIdentifier(at helperExecutableURL: URL) -> String {
    operations.append(.team(helperExecutableURL))
    return teamIdentifier
  }

  func staticCodeIsValid(at url: URL, requirementSource: String?) -> Bool {
    operations.append(.staticCode(url, requirement: requirementSource))
    return staticResults.removeFirst()
  }

  func processIsValid(_ processID: pid_t, requirementSource: String) -> Bool {
    operations.append(.process(processID, requirement: requirementSource))
    return processResult
  }
}
