import XCTest

@testable import SymphonyDesktop

@MainActor
final class NamespaceWindowSecurityCoordinatorTests: XCTestCase {
  func testWindowCloseTracksEverySecurityOperationToCompletion() async {
    let operations = SecurityOperationRecorder()
    let coordinator = NamespaceWindowSecurityCoordinator(
      lockCredentials: {
        await operations.record("lock")
      },
      cancelAuthentication: {
        await operations.record("authentication")
      },
      stopDaemons: {
        await operations.record("daemons")
      }
    )

    coordinator.secureAfterWindowCloses()
    await coordinator.waitForCurrentOperation()

    let recordedOperations = await operations.values
    XCTAssertEqual(recordedOperations, ["lock", "authentication", "daemons"])
    XCTAssertEqual(coordinator.state, .idle)
  }

  func testFailureRemainsVisibleAndRetryable() async {
    let operation = FailOnceSecurityOperation()
    let coordinator = NamespaceWindowSecurityCoordinator(
      lockCredentials: {
        try await operation.run()
      },
      cancelAuthentication: {},
      stopDaemons: {}
    )

    coordinator.secureAfterWindowCloses()
    await coordinator.waitForCurrentOperation()
    guard case .failed(let message) = coordinator.state else {
      return XCTFail("Expected a visible failure")
    }
    XCTAssertEqual(message, "Window cleanup failed.")

    coordinator.retry()
    await coordinator.waitForCurrentOperation()
    XCTAssertEqual(coordinator.state, .idle)
  }
}

private actor SecurityOperationRecorder {
  private(set) var values: [String] = []

  func record(_ value: String) {
    values.append(value)
  }
}

private actor FailOnceSecurityOperation {
  private var shouldFail = true

  func run() throws {
    if shouldFail {
      shouldFail = false
      throw WindowSecurityTestError.failed
    }
  }
}

private enum WindowSecurityTestError: LocalizedError {
  case failed

  var errorDescription: String? {
    "Window cleanup failed."
  }
}
