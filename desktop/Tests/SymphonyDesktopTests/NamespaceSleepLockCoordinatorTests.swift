import Foundation
import XCTest

@testable import SymphonyDesktop

@MainActor
final class NamespaceSleepLockCoordinatorTests: XCTestCase {
  func testSleepAcknowledgementWaitsUntilCredentialLockCompletes() async throws {
    let source = RecordingSleepEventSource()
    let gate = SleepLockGate()
    let coordinator = NamespaceSleepLockCoordinator(eventSource: source) {
      await gate.wait()
    }
    try coordinator.start()
    let request = RecordingPowerChange()

    source.emit(request)
    await gate.waitUntilEntered()

    XCTAssertNil(request.outcome)

    await gate.open()
    await eventually { request.outcome == .allowed }
  }

  func testLockFailureRejectsCancellableSleep() async throws {
    let source = RecordingSleepEventSource()
    let coordinator = NamespaceSleepLockCoordinator(eventSource: source) {
      throw TestSleepLockError.failed
    }
    try coordinator.start()
    let request = RecordingPowerChange()

    source.emit(request)

    await eventually { request.outcome == .failed }
  }

  func testStoppingCoordinatorUnregistersPowerSource() throws {
    let source = RecordingSleepEventSource()
    let coordinator = NamespaceSleepLockCoordinator(eventSource: source) {}
    try coordinator.start()

    coordinator.stop()

    XCTAssertEqual(source.stopCount, 1)
    XCTAssertFalse(coordinator.isProtectingSleep)
  }

  func testRegistrationFailureIsObservableAndLeavesProtectionUnavailable() {
    let source = RecordingSleepEventSource(startError: TestSleepLockError.failed)
    let coordinator = NamespaceSleepLockCoordinator(eventSource: source) {}

    XCTAssertThrowsError(try coordinator.start())
    XCTAssertFalse(coordinator.isProtectingSleep)
  }

  func testFailedWindowCleanupDoesNotStopApplicationSleepProtection() async throws {
    let sleepCoordinator = NamespaceSleepLockCoordinator(
      eventSource: RecordingSleepEventSource()
    ) {}
    try sleepCoordinator.start()
    let windowCoordinator = NamespaceWindowSecurityCoordinator(
      lockCredentials: {
        throw TestSleepLockError.failed
      },
      cancelAuthentication: {},
      stopDaemons: {}
    )

    windowCoordinator.secureAfterWindowCloses()
    await windowCoordinator.waitForCurrentOperation()

    XCTAssertTrue(sleepCoordinator.isProtectingSleep)
  }

  private func eventually(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not satisfied", file: file, line: line)
  }
}

private final class RecordingSleepEventSource: SystemSleepEventSource, @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (any SystemSleepPowerChange) -> Void)?
  private(set) var stopCount = 0
  private let startError: Error?

  init(startError: Error? = nil) {
    self.startError = startError
  }

  func start(handler: @escaping @Sendable (any SystemSleepPowerChange) -> Void) throws {
    if let startError {
      throw startError
    }
    lock.withLock { self.handler = handler }
  }

  func stop() {
    lock.withLock {
      stopCount += 1
      handler = nil
    }
  }

  func emit(_ request: any SystemSleepPowerChange) {
    let handler = lock.withLock { self.handler }
    handler?(request)
  }
}

private final class RecordingPowerChange: SystemSleepPowerChange, @unchecked Sendable {
  enum Outcome: Equatable {
    case allowed
    case failed
  }

  private let lock = NSLock()
  private var storedOutcome: Outcome?

  var outcome: Outcome? { lock.withLock { storedOutcome } }
  func allow() { lock.withLock { storedOutcome = .allowed } }
  func fail() { lock.withLock { storedOutcome = .failed } }
}

private actor SleepLockGate {
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

private enum TestSleepLockError: Error {
  case failed
}
