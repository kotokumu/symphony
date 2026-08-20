import Foundation
import XCTest

@testable import SymphonyDesktop
@testable import SymphonyDesktopCore

@MainActor
final class NamespaceLockControllerTests: XCTestCase {
  func testUnlockDenialLeavesNamespaceLockedAndRecoverable() async {
    let namespaceID = UUID()
    let broker = RecordingCredentialBroker()
    await broker.failNextUnlock()
    let controller = NamespaceLockController(broker: broker)

    await controller.unlock(namespaceID)

    XCTAssertEqual(controller.state(for: namespaceID), .locked(message: "Unlock denied."))

    await controller.unlock(namespaceID)

    XCTAssertEqual(controller.state(for: namespaceID), .unlocked)
  }

  func testLockingOneNamespaceDoesNotChangeAnother() async throws {
    let first = UUID()
    let second = UUID()
    let broker = RecordingCredentialBroker()
    let controller = NamespaceLockController(broker: broker)
    await controller.unlock(first)
    await controller.unlock(second)

    try await controller.lock(first)

    XCTAssertEqual(controller.state(for: first), .locked())
    XCTAssertEqual(controller.state(for: second), .unlocked)
  }

  func testLockAllProjectsEveryKnownNamespaceAsLocked() async throws {
    let first = UUID()
    let second = UUID()
    let broker = RecordingCredentialBroker()
    let controller = NamespaceLockController(broker: broker)
    await controller.unlock(first)
    await controller.unlock(second)

    try await controller.lockAll()

    XCTAssertEqual(controller.state(for: first), .locked())
    XCTAssertEqual(controller.state(for: second), .locked())
  }

  func testLockFailureRemainsVisibleAndRetryable() async throws {
    let namespaceID = UUID()
    let broker = RecordingCredentialBroker()
    let controller = NamespaceLockController(broker: broker)
    await controller.unlock(namespaceID)
    await broker.failNextLock()

    do {
      try await controller.lock(namespaceID)
      XCTFail("Expected lock to fail")
    } catch {}

    XCTAssertEqual(controller.state(for: namespaceID), .lockFailed(message: "Lock failed."))

    try await controller.lock(namespaceID)
    XCTAssertEqual(controller.state(for: namespaceID), .locked())
  }

  func testUnavailableSleepProtectionPreventsCredentialUnlock() async {
    let namespaceID = UUID()
    let broker = RecordingCredentialBroker()
    let controller = NamespaceLockController(
      broker: broker,
      sleepProtectionAvailable: false
    )

    await controller.unlock(namespaceID)

    XCTAssertEqual(
      controller.state(for: namespaceID),
      .locked(
        message: "Credentials cannot be unlocked because system sleep protection is unavailable."
      )
    )
    let isUnlocked = await broker.isUnlocked(namespaceID)
    XCTAssertFalse(isUnlocked)
  }
}

private actor RecordingCredentialBroker: NamespaceCredentialBrokering {
  private var unlocked: Set<UUID> = []
  private var shouldFailUnlock = false
  private var shouldFailLock = false

  func unlock(namespaceID: UUID) throws {
    if shouldFailUnlock {
      shouldFailUnlock = false
      throw TestCredentialBrokerError.unlockDenied
    }
    unlocked.insert(namespaceID)
  }

  func lock(namespaceID: UUID) throws {
    if shouldFailLock {
      shouldFailLock = false
      throw TestCredentialBrokerError.lockFailed
    }
    unlocked.remove(namespaceID)
  }

  func lockAll() throws { unlocked.removeAll() }
  func shutdownForApplicationTermination() throws { unlocked.removeAll() }
  func resumeAfterApplicationTerminationFailure() {}
  func removeNamespace(_ namespaceID: UUID) throws { unlocked.remove(namespaceID) }
  func isUnlocked(_ namespaceID: UUID) -> Bool { unlocked.contains(namespaceID) }
  func failNextUnlock() { shouldFailUnlock = true }
  func failNextLock() { shouldFailLock = true }
}

private enum TestCredentialBrokerError: LocalizedError {
  case unlockDenied
  case lockFailed

  var errorDescription: String? {
    switch self {
    case .unlockDenied: "Unlock denied."
    case .lockFailed: "Lock failed."
    }
  }
}
