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

  func testTerminationWaitsForWindowCleanupBeforeStartingItsShutdown() async {
    let gate = WindowSecurityGate()
    let shutdownStarted = SecurityOperationRecorder()
    let coordinator = NamespaceWindowSecurityCoordinator(
      lockCredentials: {
        await gate.wait()
      },
      cancelAuthentication: {},
      stopDaemons: {}
    )
    coordinator.secureAfterWindowCloses()
    await gate.waitUntilEntered()

    let termination = Task { @MainActor in
      await coordinator.waitForCurrentOperation()
      await shutdownStarted.record("shutdown")
    }
    try? await Task.sleep(for: .milliseconds(20))
    let beforeRelease = await shutdownStarted.values
    XCTAssertTrue(beforeRelease.isEmpty)

    await gate.open()
    await termination.value
    let afterRelease = await shutdownStarted.values
    XCTAssertEqual(afterRelease, ["shutdown"])
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

private actor WindowSecurityGate {
  private var entered = false
  private var isOpen = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var openWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered = true
    entryWaiters.forEach { $0.resume() }
    entryWaiters.removeAll()
    if isOpen { return }
    await withCheckedContinuation { continuation in
      openWaiters.append(continuation)
    }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    openWaiters.forEach { $0.resume() }
    openWaiters.removeAll()
  }
}
