import Foundation
import XCTest

@testable import SymphonyCredentialBrokerProtocol
@testable import SymphonyDesktopCore
@testable import SymphonyDesktopInfrastructure

private extension NamespaceCredentialBrokerSessionHandle {
  func authorizeGitHubRepository(_ authorization: GitHubRepositoryAuthorization) async throws {
    throw TestBrokerCapabilityError.unsupported
  }

  func performGitHubIssueRequest(
    _ request: GitHubIssueCapabilityRequest
  ) async throws -> GitHubIssueCapabilityResponse {
    throw TestBrokerCapabilityError.unsupported
  }

  func performGitHubGitOperation(
    _ request: GitRepositoryCapabilityRequest
  ) async throws -> GitRepositoryCapabilityResult {
    throw TestBrokerCapabilityError.unsupported
  }
}

private enum TestBrokerCapabilityError: Error {
  case unsupported
}

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

  func testGitHubCapabilitiesAndRemovalRemainNamespaceScoped() async throws {
    let first = UUID()
    let second = UUID()
    let launcher = RecordingBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.unlock(namespaceID: first)
    try await broker.unlock(namespaceID: second)

    let firstInstallations = try await broker.discoverGitHubInstallations(namespaceID: first)
    let secondInstallations = try await broker.discoverGitHubInstallations(namespaceID: second)
    XCTAssertEqual(firstInstallations.first?.accountLogin, first.uuidString.lowercased())
    XCTAssertEqual(secondInstallations.first?.accountLogin, second.uuidString.lowercased())

    try await broker.removeGitHubAppCredential(namespaceID: first)

    do {
      _ = try await broker.discoverGitHubInstallations(namespaceID: first)
      XCTFail("Expected removed namespace capability to be locked")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Protected namespace credentials are locked.")
    }
    let stillAvailable = try await broker.discoverGitHubInstallations(namespaceID: second)
    XCTAssertEqual(stillAvailable.first?.accountLogin, second.uuidString.lowercased())
  }

  func testRemovalCoalescesWithInFlightLockBeforePurging() async throws {
    let namespaceID = UUID()
    let launcher = GatedCapabilityBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.unlock(namespaceID: namespaceID)
    let removal = Task {
      try await broker.removeGitHubAppCredential(namespaceID: namespaceID)
    }
    await launcher.waitUntilLockStarted()

    let lockAll = Task { try await broker.lockAll() }
    await launcher.completeLock()
    try await removal.value
    try await lockAll.value
    let events = await launcher.events
    XCTAssertEqual(events, ["lock-started", "lock-finished", "purge-started", "purge-finished"])
  }

  func testSharedLockFailureRetainsOwnershipAndAllowsRemovalRetry() async throws {
    let namespaceID = UUID()
    let launcher = GatedCapabilityBrokerLauncher()
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.unlock(namespaceID: namespaceID)
    let removal = Task {
      try await broker.removeGitHubAppCredential(namespaceID: namespaceID)
    }
    await launcher.waitUntilLockStarted()

    let lockAll = Task { try await broker.lockAll() }
    await launcher.failLock()

    do {
      try await removal.value
      XCTFail("Expected removal to receive the shared lock failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("gated lock failed"))
    }
    do {
      try await lockAll.value
      XCTFail("Expected lockAll to receive the shared lock failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("1 namespace"))
    }
    let remainedUnlocked = await broker.isUnlocked(namespaceID)
    let failedEvents = await launcher.events
    XCTAssertTrue(remainedUnlocked)
    XCTAssertEqual(failedEvents, ["lock-started", "lock-failed"])

    await launcher.allowLocks()
    let retry = Task {
      try await broker.removeGitHubAppCredential(namespaceID: namespaceID)
    }
    await launcher.waitUntilLockStarted()
    await launcher.completeLock()
    try await retry.value
    let retryEvents = await launcher.events
    XCTAssertEqual(
      retryEvents,
      [
        "lock-started", "lock-failed", "lock-started", "lock-finished",
        "purge-started", "purge-finished",
      ]
    )
  }

  func testRemovalKeepsAdmissionClosedAndCoalescesWhilePurgeIsRunning() async throws {
    let namespaceID = UUID()
    let launcher = GatedCapabilityBrokerLauncher(gatesFirstPurge: true)
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.unlock(namespaceID: namespaceID)
    let firstRemoval = Task {
      try await broker.removeGitHubAppCredential(namespaceID: namespaceID)
    }
    await launcher.waitUntilLockStarted()
    await launcher.completeLock()
    await launcher.waitUntilPurgeStarted()

    do {
      try await broker.unlock(namespaceID: namespaceID)
      XCTFail("Expected unlock to remain closed during purge")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("security operation"))
    }
    let secondRemoval = Task {
      try await broker.removeGitHubAppCredential(namespaceID: namespaceID)
    }

    await launcher.completePurge()
    try await firstRemoval.value
    try await secondRemoval.value
    let events = await launcher.events
    let unlockCount = await launcher.unlockCount
    XCTAssertEqual(events.filter { $0 == "purge-started" }.count, 1)
    XCTAssertEqual(events.filter { $0 == "purge-finished" }.count, 1)
    XCTAssertEqual(unlockCount, 1)
  }

  func testPurgeFailureIsSharedAndRemovalCanRetry() async throws {
    let namespaceID = UUID()
    let launcher = GatedCapabilityBrokerLauncher(
      gatesFirstPurge: true,
      purgesShouldFail: true
    )
    let broker = NamespaceCredentialBroker(launcher: launcher)
    try await broker.unlock(namespaceID: namespaceID)
    let firstRemoval = Task {
      try await broker.removeGitHubAppCredential(namespaceID: namespaceID)
    }
    await launcher.waitUntilLockStarted()
    await launcher.completeLock()
    await launcher.waitUntilPurgeStarted()

    do {
      try await broker.unlock(namespaceID: namespaceID)
      XCTFail("Expected unlock to remain closed during purge")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("security operation"))
    }
    let secondRemoval = Task {
      try await broker.removeGitHubAppCredential(namespaceID: namespaceID)
    }
    let lockAll = Task { try await broker.lockAll() }
    await launcher.completePurge()

    do {
      try await firstRemoval.value
      XCTFail("Expected the first removal to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("gated purge failed"))
    }
    do {
      try await secondRemoval.value
      XCTFail("Expected the coalesced removal to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("gated purge failed"))
    }
    do {
      try await lockAll.value
      XCTFail("Expected lockAll to receive the removal failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("1 namespace"))
    }
    let failedEvents = await launcher.events
    XCTAssertEqual(
      failedEvents,
      ["lock-started", "lock-finished", "purge-started", "purge-failed"]
    )

    await launcher.allowPurges()
    try await broker.removeGitHubAppCredential(namespaceID: namespaceID)
    let retryEvents = await launcher.events
    XCTAssertEqual(
      retryEvents,
      [
        "lock-started", "lock-finished", "purge-started", "purge-failed",
        "purge-started", "purge-finished",
      ]
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

  func unlock(namespaceID: UUID) async throws -> any NamespaceCredentialBrokerSessionHandle {
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

private actor RecordingBrokerSession: NamespaceCredentialBrokerSessionHandle {
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

  func configureGitHubApp(appID: Int64, privateKeyFileURL: URL) async throws {}
  func listGitHubInstallations() async throws -> [GitHubInstallationDescriptor] {
    [
      GitHubInstallationDescriptor(
        id: 20,
        accountLogin: namespaceID.uuidString.lowercased(),
        accountType: "Organization",
        permissions: ["issues": "read", "contents": "write"],
        isSuspended: false
      )
    ]
  }
  func listGitHubRepositories(installationID: Int64) async throws
    -> [GitHubRepositoryDescriptor] { [] }
}

private actor GatedBrokerLauncher: CredentialBrokerSessionLaunching {
  private var unlockStarted = false
  private var unlockStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var unlockContinuation: CheckedContinuation<Void, Never>?
  private(set) var ownsSession = false

  func unlock(namespaceID: UUID) async throws -> any NamespaceCredentialBrokerSessionHandle {
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

private struct GatedBrokerSession: NamespaceCredentialBrokerSessionHandle {
  let namespaceID: UUID
  let launcher: GatedBrokerLauncher

  func lock() async throws {
    await launcher.stop(namespaceID: namespaceID)
  }

  func signChallenge(_ challenge: Data) async throws -> Data { challenge }

  func configureGitHubApp(appID: Int64, privateKeyFileURL: URL) async throws {}
  func listGitHubInstallations() async throws -> [GitHubInstallationDescriptor] { [] }
  func listGitHubRepositories(installationID: Int64) async throws
    -> [GitHubRepositoryDescriptor] { [] }
}

private actor FailingPendingBrokerLauncher: CredentialBrokerSessionLaunching {
  private var stopShouldFail = true
  private var launchShouldFail = true
  private(set) var ownsSession = false

  func unlock(namespaceID: UUID) async throws -> any NamespaceCredentialBrokerSessionHandle {
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

private struct FailingPendingBrokerSession: NamespaceCredentialBrokerSessionHandle {
  let namespaceID: UUID
  let launcher: FailingPendingBrokerLauncher

  func lock() async throws {
    try await launcher.stop(namespaceID: namespaceID)
  }

  func signChallenge(_ challenge: Data) async throws -> Data { challenge }

  func configureGitHubApp(appID: Int64, privateKeyFileURL: URL) async throws {}
  func listGitHubInstallations() async throws -> [GitHubInstallationDescriptor] { [] }
  func listGitHubRepositories(installationID: Int64) async throws
    -> [GitHubRepositoryDescriptor] { [] }
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
  private let gatesFirstPurge: Bool
  private var purgesShouldFail: Bool
  private var lockStarted = false
  private var locksShouldFail = false
  private var lockStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var lockContinuation: CheckedContinuation<Void, any Error>?
  private var purgeStarted = false
  private var purgeStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var purgeContinuation: CheckedContinuation<Void, Never>?
  private var purgeCount = 0
  private(set) var capabilityCount = 0
  private(set) var events: [String] = []
  private(set) var unlockCount = 0

  init(gatesFirstPurge: Bool = false, purgesShouldFail: Bool = false) {
    self.gatesFirstPurge = gatesFirstPurge
    self.purgesShouldFail = purgesShouldFail
  }

  func unlock(namespaceID: UUID) -> any NamespaceCredentialBrokerSessionHandle {
    unlockCount += 1
    return GatedCapabilityBrokerSession(namespaceID: namespaceID, launcher: self)
  }

  func stop(namespaceID: UUID) {}
  func purge(namespaceID: UUID) async throws {
    purgeCount += 1
    events.append("purge-started")
    purgeStarted = true
    purgeStartWaiters.forEach { $0.resume() }
    purgeStartWaiters.removeAll()
    if gatesFirstPurge, purgeCount == 1 {
      await withCheckedContinuation { continuation in
        purgeContinuation = continuation
      }
    }
    if purgesShouldFail {
      events.append("purge-failed")
      throw TestGatedPurgeError.failed
    }
    events.append("purge-finished")
  }

  func beginLock() async throws {
    lockStarted = true
    events.append("lock-started")
    lockStartWaiters.forEach { $0.resume() }
    lockStartWaiters.removeAll()
    if locksShouldFail {
      lockStarted = false
      events.append("lock-failed")
      throw TestGatedLockError.failed
    }
    try await withCheckedThrowingContinuation { continuation in
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
    lockStarted = false
    events.append("lock-finished")
    lockContinuation?.resume(returning: ())
    lockContinuation = nil
  }

  func failLock() {
    locksShouldFail = true
    lockStarted = false
    events.append("lock-failed")
    lockContinuation?.resume(throwing: TestGatedLockError.failed)
    lockContinuation = nil
  }

  func allowLocks() {
    locksShouldFail = false
  }

  func waitUntilPurgeStarted() async {
    if purgeStarted { return }
    await withCheckedContinuation { continuation in
      purgeStartWaiters.append(continuation)
    }
  }

  func completePurge() {
    purgeContinuation?.resume()
    purgeContinuation = nil
  }

  func allowPurges() {
    purgesShouldFail = false
  }
}

private enum TestGatedLockError: LocalizedError {
  case failed

  var errorDescription: String? { "The gated lock failed." }
}

private enum TestGatedPurgeError: LocalizedError {
  case failed

  var errorDescription: String? { "The gated purge failed." }
}

private struct GatedCapabilityBrokerSession: NamespaceCredentialBrokerSessionHandle {
  let namespaceID: UUID
  let launcher: GatedCapabilityBrokerLauncher

  func lock() async throws {
    try await launcher.beginLock()
  }

  func signChallenge(_ challenge: Data) async throws -> Data {
    await launcher.recordCapability()
    return challenge
  }

  func configureGitHubApp(appID: Int64, privateKeyFileURL: URL) async throws {}
  func listGitHubInstallations() async throws -> [GitHubInstallationDescriptor] { [] }
  func listGitHubRepositories(installationID: Int64) async throws
    -> [GitHubRepositoryDescriptor] { [] }
}
