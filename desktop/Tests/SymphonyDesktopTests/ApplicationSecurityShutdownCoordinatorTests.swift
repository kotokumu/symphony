import XCTest

@testable import SymphonyDesktop

@MainActor
final class ApplicationSecurityShutdownCoordinatorTests: XCTestCase {
  func testCloseThenQuitWaitsForWindowCleanupThroughProductionCoordinator() async throws {
    let gate = ApplicationShutdownGate()
    let operations = ApplicationShutdownRecorder()
    let window = NamespaceWindowSecurityCoordinator(
      lockCredentials: {
        await gate.wait()
      },
      cancelAuthentication: {},
      stopDaemons: {}
    )
    let coordinator = ApplicationSecurityShutdownCoordinator(
      windowSecurity: window,
      lockCredentials: {
        operations.record("credentials")
      },
      shutdownAuthentication: {
        operations.record("authentication")
      },
      shutdownDaemons: {
        operations.record("daemons")
      },
      stopSleepProtection: {
        operations.record("sleep")
      },
      resumeAuthentication: {},
      resumeCredentials: {}
    )
    window.secureAfterWindowCloses()
    await gate.waitUntilEntered()

    let shutdown = Task {
      try await coordinator.shutdown()
    }
    try await Task.sleep(for: .milliseconds(20))
    let beforeRelease = operations.values
    XCTAssertTrue(beforeRelease.isEmpty)

    await gate.open()
    try await shutdown.value
    let afterRelease = operations.values
    XCTAssertEqual(afterRelease, ["credentials", "authentication", "daemons", "sleep"])
  }

  func testFailedShutdownResumesAdmissionAndCanBeRetried() async throws {
    let operation = FailOnceApplicationShutdownOperation()
    let operations = ApplicationShutdownRecorder()
    let window = NamespaceWindowSecurityCoordinator(
      lockCredentials: {},
      cancelAuthentication: {},
      stopDaemons: {}
    )
    let coordinator = ApplicationSecurityShutdownCoordinator(
      windowSecurity: window,
      lockCredentials: {
        try await operation.run()
      },
      shutdownAuthentication: {},
      shutdownDaemons: {},
      stopSleepProtection: {
        operations.record("sleep")
      },
      resumeAuthentication: {
        operations.record("resume-authentication")
      },
      resumeCredentials: {
        operations.record("resume-credentials")
      }
    )

    do {
      try await coordinator.shutdown()
      XCTFail("Expected the first shutdown to fail")
    } catch {}
    let failureOperations = operations.values
    XCTAssertEqual(failureOperations, ["resume-authentication", "resume-credentials"])

    try await coordinator.shutdown()
    XCTAssertTrue(operations.values.contains("sleep"))
  }
}

private final class ApplicationShutdownRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValues: [String] = []

  func record(_ value: String) {
    lock.withLock { recordedValues.append(value) }
  }

  var values: [String] { lock.withLock { recordedValues } }
}

private actor FailOnceApplicationShutdownOperation {
  private var shouldFail = true

  func run() throws {
    if shouldFail {
      shouldFail = false
      throw ApplicationShutdownTestError.failed
    }
  }
}

private actor ApplicationShutdownGate {
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

private enum ApplicationShutdownTestError: Error {
  case failed
}
