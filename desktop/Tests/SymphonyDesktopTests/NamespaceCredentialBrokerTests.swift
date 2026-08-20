import Foundation
import XCTest

@testable import SymphonyDesktopCore
@testable import SymphonyDesktopInfrastructure

final class NamespaceCredentialBrokerTests: XCTestCase {
  func testLockingOneNamespaceLeavesAnotherSessionUnlocked() async throws {
    let first = UUID()
    let second = UUID()
    let launcher = RecordingBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)

    try await broker.unlock(namespaceID: first)
    try await broker.unlock(namespaceID: second)
    try await broker.lock(namespaceID: first)

    let firstIsUnlocked = await broker.isUnlocked(first)
    let secondIsUnlocked = await broker.isUnlocked(second)
    let firstLockCount = await launcher.lockCount(for: first)
    let secondLockCount = await launcher.lockCount(for: second)
    XCTAssertFalse(firstIsUnlocked)
    XCTAssertTrue(secondIsUnlocked)
    XCTAssertEqual(firstLockCount, 1)
    XCTAssertEqual(secondLockCount, 0)
  }

  func testLockAllClearsEveryOwnedSession() async throws {
    let first = UUID()
    let second = UUID()
    let launcher = RecordingBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.unlock(namespaceID: first)
    try await broker.unlock(namespaceID: second)

    try await broker.lockAll()

    let firstIsUnlocked = await broker.isUnlocked(first)
    let secondIsUnlocked = await broker.isUnlocked(second)
    let firstLockCount = await launcher.lockCount(for: first)
    let secondLockCount = await launcher.lockCount(for: second)
    XCTAssertFalse(firstIsUnlocked)
    XCTAssertFalse(secondIsUnlocked)
    XCTAssertEqual(firstLockCount, 1)
    XCTAssertEqual(secondLockCount, 1)
  }

  func testApplicationTerminationBlocksNewUnlocksUntilResumed() async throws {
    let launcher = RecordingBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.shutdownForApplicationTermination()

    do {
      try await broker.unlock(namespaceID: UUID())
      XCTFail("Expected unlock admission to be closed")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace credentials cannot be unlocked while another security operation is running."
      )
    }

    await broker.resumeAfterApplicationTerminationFailure()
    try await broker.unlock(namespaceID: UUID())
  }

  func testRemoveNamespaceLocksItsSessionBeforePurgingStorage() async throws {
    let namespaceID = UUID()
    let launcher = RecordingBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.unlock(namespaceID: namespaceID)

    try await broker.removeNamespace(namespaceID)

    let operations = await launcher.operations
    XCTAssertEqual(
      operations,
      [.unlock(namespaceID), .lock(namespaceID), .purge(namespaceID)]
    )
  }
}

private actor RecordingBrokerLauncher: CredentialBrokerSessionLaunching {
  enum Operation: Equatable {
    case unlock(UUID)
    case lock(UUID)
    case purge(UUID)
  }

  private(set) var operations: [Operation] = []

  func unlock(namespaceID: UUID) async throws -> any CredentialBrokerSessionHandle {
    operations.append(.unlock(namespaceID))
    return RecordingBrokerSession(namespaceID: namespaceID, launcher: self)
  }

  func purge(namespaceID: UUID) async throws {
    operations.append(.purge(namespaceID))
  }

  func recordLock(_ namespaceID: UUID) {
    operations.append(.lock(namespaceID))
  }

  func lockCount(for namespaceID: UUID) -> Int {
    operations.filter { $0 == .lock(namespaceID) }.count
  }
}

private actor RecordingBrokerSession: CredentialBrokerSessionHandle {
  let namespaceID: UUID
  let launcher: RecordingBrokerLauncher
  private var locked = false

  init(namespaceID: UUID, launcher: RecordingBrokerLauncher) {
    self.namespaceID = namespaceID
    self.launcher = launcher
  }

  func lock() async throws {
    guard !locked else { return }
    locked = true
    await launcher.recordLock(namespaceID)
  }
}
