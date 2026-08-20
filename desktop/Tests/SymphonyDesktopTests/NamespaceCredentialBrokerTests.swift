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

  func testCapabilityResultIsScopedToAnUnlockedNamespace() async throws {
    let namespaceID = UUID()
    let otherNamespaceID = UUID()
    let launcher = RecordingBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.unlock(namespaceID: namespaceID)

    let result = try await broker.signChallenge(Data([1, 2]), namespaceID: namespaceID)

    XCTAssertEqual(result, Data([2, 1]))
    do {
      _ = try await broker.signChallenge(Data([1]), namespaceID: otherNamespaceID)
      XCTFail("Expected locked namespace rejection")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Protected namespace credentials are locked.")
    }
  }

  func testLockDuringPendingUnlockRejectsReplacementAndPreventsStalePublication() async throws {
    let namespaceID = UUID()
    let launcher = GatedBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)
    let unlock = Task {
      try await broker.unlock(namespaceID: namespaceID)
    }
    await launcher.waitUntilUnlockStarted()

    let lock = Task {
      try await broker.lock(namespaceID: namespaceID)
    }
    await Task.yield()

    do {
      try await broker.unlock(namespaceID: namespaceID)
      XCTFail("Expected replacement unlock to be rejected")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace credentials cannot be unlocked while another security operation is running."
      )
    }

    await launcher.completeUnlock()
    try await lock.value
    do {
      try await unlock.value
      XCTFail("Expected stale unlock to be interrupted")
    } catch {}

    let isUnlocked = await broker.isUnlocked(namespaceID)
    let launcherOwnsSession = await launcher.ownsSession
    XCTAssertFalse(isUnlocked)
    XCTAssertFalse(launcherOwnsSession)
  }

  func testFailedPendingStopRetainsOwnershipUntilProductionRetrySucceeds() async throws {
    let namespaceID = UUID()
    let launcher = FailingPendingBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)

    do {
      try await broker.unlock(namespaceID: namespaceID)
      XCTFail("Expected launch failure")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Stop failed.")
    }

    do {
      try await broker.unlock(namespaceID: namespaceID)
      XCTFail("Expected retained ownership to block replacement")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Namespace credentials cannot be unlocked while another security operation is running."
      )
    }

    try await broker.lock(namespaceID: namespaceID)

    let ownsSession = await launcher.ownsSession
    XCTAssertFalse(ownsSession)
    try await broker.unlock(namespaceID: namespaceID)
  }

  func testLockAdmissionRejectsNewCapabilitiesBeforeSessionStopCompletes() async throws {
    let namespaceID = UUID()
    let launcher = GatedCapabilityBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.unlock(namespaceID: namespaceID)

    let lock = Task {
      try await broker.lock(namespaceID: namespaceID)
    }
    await launcher.waitUntilLockStarted()

    do {
      _ = try await broker.signChallenge(Data([1]), namespaceID: namespaceID)
      XCTFail("Expected capability admission to close while locking")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Protected namespace credentials are locked.")
    }
    let capabilityCount = await launcher.capabilityCount
    XCTAssertEqual(capabilityCount, 0)

    await launcher.completeLock()
    try await lock.value
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

  func stop(namespaceID: UUID) async throws {}

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

  func signChallenge(_ challenge: Data) async throws -> Data {
    Data(challenge.reversed())
  }
}

private actor GatedBrokerLauncher: CredentialBrokerSessionLaunching {
  private var unlockStarted = false
  private var unlockStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var unlockContinuation: CheckedContinuation<Void, Never>?
  private(set) var ownsSession = false

  func unlock(namespaceID: UUID) async throws -> any CredentialBrokerSessionHandle {
    unlockStarted = true
    unlockStartWaiters.forEach { $0.resume() }
    unlockStartWaiters.removeAll()
    await withCheckedContinuation { continuation in
      unlockContinuation = continuation
    }
    ownsSession = true
    return GatedBrokerSession(namespaceID: namespaceID, launcher: self)
  }

  func stop(namespaceID: UUID) {
    ownsSession = false
  }

  func purge(namespaceID: UUID) {}

  func waitUntilUnlockStarted() async {
    if unlockStarted { return }
    await withCheckedContinuation { continuation in
      unlockStartWaiters.append(continuation)
    }
  }

  func completeUnlock() {
    unlockContinuation?.resume()
    unlockContinuation = nil
  }
}

private struct GatedBrokerSession: CredentialBrokerSessionHandle {
  let namespaceID: UUID
  let launcher: GatedBrokerLauncher

  func lock() async throws {
    await launcher.stop(namespaceID: namespaceID)
  }

  func signChallenge(_ challenge: Data) async throws -> Data { challenge }
}

private actor FailingPendingBrokerLauncher: CredentialBrokerSessionLaunching {
  private var stopShouldFail = true
  private var launchShouldFail = true
  private(set) var ownsSession = false

  func unlock(namespaceID: UUID) async throws -> any CredentialBrokerSessionHandle {
    ownsSession = true
    if launchShouldFail {
      launchShouldFail = false
      throw TestPendingBrokerError.handshakeFailed
    }
    return FailingPendingBrokerSession(namespaceID: namespaceID, launcher: self)
  }

  func stop(namespaceID: UUID) throws {
    if stopShouldFail {
      stopShouldFail = false
      throw TestPendingBrokerError.stopFailed
    }
    ownsSession = false
  }

  func purge(namespaceID: UUID) {}
}

private struct FailingPendingBrokerSession: CredentialBrokerSessionHandle {
  let namespaceID: UUID
  let launcher: FailingPendingBrokerLauncher

  func lock() async throws {
    try await launcher.stop(namespaceID: namespaceID)
  }

  func signChallenge(_ challenge: Data) async throws -> Data { challenge }
}

private enum TestPendingBrokerError: LocalizedError {
  case handshakeFailed
  case stopFailed

  var errorDescription: String? {
    switch self {
    case .handshakeFailed: "Handshake failed."
    case .stopFailed: "Stop failed."
    }
  }
}

private actor GatedCapabilityBrokerLauncher: CredentialBrokerSessionLaunching {
  private var lockStarted = false
  private var lockStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var lockContinuation: CheckedContinuation<Void, Never>?
  private(set) var capabilityCount = 0

  func unlock(namespaceID: UUID) -> any CredentialBrokerSessionHandle {
    GatedCapabilityBrokerSession(namespaceID: namespaceID, launcher: self)
  }

  func stop(namespaceID: UUID) {}
  func purge(namespaceID: UUID) {}

  func beginLock() async {
    lockStarted = true
    lockStartWaiters.forEach { $0.resume() }
    lockStartWaiters.removeAll()
    await withCheckedContinuation { continuation in
      lockContinuation = continuation
    }
  }

  func recordCapability() {
    capabilityCount += 1
  }

  func waitUntilLockStarted() async {
    if lockStarted { return }
    await withCheckedContinuation { continuation in
      lockStartWaiters.append(continuation)
    }
  }

  func completeLock() {
    lockContinuation?.resume()
    lockContinuation = nil
  }
}

private struct GatedCapabilityBrokerSession: CredentialBrokerSessionHandle {
  let namespaceID: UUID
  let launcher: GatedCapabilityBrokerLauncher

  func lock() async throws {
    await launcher.beginLock()
  }

  func signChallenge(_ challenge: Data) async throws -> Data {
    await launcher.recordCapability()
    return challenge
  }
}
