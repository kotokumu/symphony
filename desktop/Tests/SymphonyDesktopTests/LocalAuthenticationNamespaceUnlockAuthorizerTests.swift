import Foundation
import LocalAuthentication
import XCTest

@testable import SymphonyCredentialBrokerKit

final class LocalAuthenticationNamespaceUnlockAuthorizerTests: XCTestCase {
  func testRequestsDeviceOwnerAuthenticationWithTheUnlockReason() async throws {
    let context = RecordingAuthenticationContext()
    let authorizer = LocalAuthenticationNamespaceUnlockAuthorizer { context }

    _ = try await authorizer.authorize(reason: "Unlock Research")

    XCTAssertEqual(context.canEvaluatePolicies, [.deviceOwnerAuthentication])
    XCTAssertEqual(
      context.evaluations,
      [.init(policy: .deviceOwnerAuthentication, reason: "Unlock Research")]
    )
  }

  func testUnavailablePolicyProducesActionableFailure() async {
    let context = RecordingAuthenticationContext(
      canEvaluate: false,
      availabilityError: NSError(domain: LAError.errorDomain, code: LAError.biometryNotAvailable.rawValue)
    )
    let authorizer = LocalAuthenticationNamespaceUnlockAuthorizer { context }

    do {
      _ = try await authorizer.authorize(reason: "Unlock")
      XCTFail("Expected authentication to be unavailable")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("cannot be unlocked"))
    }
    XCTAssertEqual(context.invalidateCount, 1)
  }

  func testCancellationCodesMapToCancelledAndInvalidateContext() async {
    for code in [LAError.userCancel, .appCancel, .systemCancel] {
      let context = RecordingAuthenticationContext(
        evaluationError: NSError(domain: LAError.errorDomain, code: code.rawValue)
      )
      let authorizer = LocalAuthenticationNamespaceUnlockAuthorizer { context }

      do {
        _ = try await authorizer.authorize(reason: "Unlock")
        XCTFail("Expected cancellation")
      } catch {
        XCTAssertEqual(error.localizedDescription, "Namespace unlock was cancelled.")
      }
      XCTAssertEqual(context.invalidateCount, 1)
    }
  }

  func testAuthenticationFailureMapsToDeniedAndInvalidatesContext() async {
    let context = RecordingAuthenticationContext(
      evaluationError: NSError(
        domain: LAError.errorDomain,
        code: LAError.authenticationFailed.rawValue
      )
    )
    let authorizer = LocalAuthenticationNamespaceUnlockAuthorizer { context }

    do {
      _ = try await authorizer.authorize(reason: "Unlock")
      XCTFail("Expected denial")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Namespace unlock was not authorized.")
    }
    XCTAssertEqual(context.invalidateCount, 1)
  }

  func testFalseEvaluationMapsToDeniedAndInvalidatesContext() async {
    let context = RecordingAuthenticationContext(evaluationResult: false)
    let authorizer = LocalAuthenticationNamespaceUnlockAuthorizer { context }

    do {
      _ = try await authorizer.authorize(reason: "Unlock")
      XCTFail("Expected denial")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Namespace unlock was not authorized.")
    }
    XCTAssertEqual(context.invalidateCount, 1)
  }
}

private final class RecordingAuthenticationContext: NamespaceDeviceOwnerAuthenticationContext,
  @unchecked Sendable
{
  struct Evaluation: Equatable {
    let policy: LAPolicy
    let reason: String
  }

  let localAuthenticationContext = LAContext()
  private let canEvaluate: Bool
  private let availabilityError: NSError?
  private let evaluationError: NSError?
  private let evaluationResult: Bool
  private(set) var canEvaluatePolicies: [LAPolicy] = []
  private(set) var evaluations: [Evaluation] = []
  private(set) var invalidateCount = 0

  init(
    canEvaluate: Bool = true,
    availabilityError: NSError? = nil,
    evaluationError: NSError? = nil,
    evaluationResult: Bool = true
  ) {
    self.canEvaluate = canEvaluate
    self.availabilityError = availabilityError
    self.evaluationError = evaluationError
    self.evaluationResult = evaluationResult
  }

  func canEvaluatePolicy(_ policy: LAPolicy, error: inout NSError?) -> Bool {
    canEvaluatePolicies.append(policy)
    error = availabilityError
    return canEvaluate
  }

  func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
    evaluations.append(.init(policy: policy, reason: localizedReason))
    if let evaluationError { throw evaluationError }
    return evaluationResult
  }

  func invalidate() {
    invalidateCount += 1
  }
}
