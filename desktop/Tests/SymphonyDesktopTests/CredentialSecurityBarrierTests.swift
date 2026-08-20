import XCTest

@testable import SymphonyDesktop

@MainActor
final class CredentialSecurityBarrierTests: XCTestCase {
  func testLockIsAttemptedWhenGitHubQuiescenceFails() async {
    var operations: [String] = []
    let barrier = CredentialSecurityBarrier(
      quiesceGitHub: {
        operations.append("quiesce")
        throw TestBarrierError.quiesce
      },
      lockCredentials: {
        operations.append("lock")
      }
    )

    do {
      try await barrier.secure()
      XCTFail("Expected the combined barrier failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Quiesce failed."))
    }
    XCTAssertEqual(operations.sorted(), ["lock", "quiesce"])
  }

  func testBothFailuresAreReportedAfterBothOperationsRun() async {
    var operations: [String] = []
    let barrier = CredentialSecurityBarrier(
      quiesceGitHub: {
        operations.append("quiesce")
        throw TestBarrierError.quiesce
      },
      lockCredentials: {
        operations.append("lock")
        throw TestBarrierError.lock
      }
    )

    do {
      try await barrier.secure()
      XCTFail("Expected the combined barrier failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Quiesce failed."))
      XCTAssertTrue(error.localizedDescription.contains("Lock failed."))
    }
    XCTAssertEqual(operations.sorted(), ["lock", "quiesce"])
  }

  func testLockStartsWhileQuiescenceIsStillWaiting() async throws {
    let gate = BarrierTestGate()
    let barrier = CredentialSecurityBarrier(
      quiesceGitHub: { await gate.waitForRelease() },
      lockCredentials: { await gate.recordLock() }
    )
    let securing = Task { try await barrier.secure() }

    await gate.waitUntilLockWasCalled()
    let lockWasCalled = await gate.lockWasCalled
    XCTAssertTrue(lockWasCalled)
    await gate.releaseQuiescence()
    try await securing.value
  }
}

private actor BarrierTestGate {
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var lockWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var lockWasCalled = false

  func waitForRelease() async {
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func recordLock() {
    lockWasCalled = true
    lockWaiters.forEach { $0.resume() }
    lockWaiters.removeAll()
  }

  func waitUntilLockWasCalled() async {
    if lockWasCalled { return }
    await withCheckedContinuation { lockWaiters.append($0) }
  }

  func releaseQuiescence() {
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

private enum TestBarrierError: LocalizedError {
  case quiesce
  case lock

  var errorDescription: String? {
    switch self {
    case .quiesce: "Quiesce failed."
    case .lock: "Lock failed."
    }
  }
}
