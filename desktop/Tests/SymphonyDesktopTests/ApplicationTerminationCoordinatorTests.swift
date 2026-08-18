import XCTest

@testable import SymphonyDesktop

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
  func testTerminationWaitsForDaemonShutdownBeforeReplying() async {
    let gate = AsyncGate()
    let replied = expectation(description: "termination replied")
    var reply: Bool?
    let coordinator = ApplicationTerminationCoordinator {
      await gate.wait()
    }

    coordinator.requestTermination { result in
      reply = (try? result.get()) != nil
      replied.fulfill()
    }
    await Task.yield()

    XCTAssertNil(reply)

    await gate.open()
    await fulfillment(of: [replied], timeout: 1)
    XCTAssertEqual(reply, true)
  }

  func testTerminationIsCancelledWhenDaemonShutdownFails() async {
    let replied = expectation(description: "termination replied")
    var reply: Bool?
    let coordinator = ApplicationTerminationCoordinator {
      throw TestTerminationError.stopFailed
    }

    coordinator.requestTermination { result in
      reply = (try? result.get()) != nil
      replied.fulfill()
    }

    await fulfillment(of: [replied], timeout: 1)
    XCTAssertEqual(reply, false)
  }
}

private actor AsyncGate {
  private var isOpen = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    if isOpen {
      return
    }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

private enum TestTerminationError: Error {
  case stopFailed
}
