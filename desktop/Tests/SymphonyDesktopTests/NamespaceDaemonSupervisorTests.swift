import Darwin
import Foundation
import XCTest

@testable import SymphonyDesktopCore
@testable import SymphonyDesktopInfrastructure

final class NamespaceDaemonSupervisorTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  func testRunsTwoNamespacesWithIsolatedRuntimeResources() async throws {
    let executable = try makeLongRunningExecutable()
    let ports = PortSequence([42001, 42001, 42002])
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: executable,
      readinessTimeout: 1,
      readinessProbe: { _ in true },
      portAllocator: { try ports.next() }
    )
    let firstID = UUID()
    let secondID = UUID()
    let firstDirectory = try makeNamespaceDirectory(firstID)
    let secondDirectory = try makeNamespaceDirectory(secondID)

    async let first: Void = supervisor.start(
      namespaceID: firstID,
      namespaceDirectory: firstDirectory
    )
    async let second: Void = supervisor.start(
      namespaceID: secondID,
      namespaceDirectory: secondDirectory
    )
    _ = await (first, second)

    let firstEndpoint = try runningEndpoint(await supervisor.state(for: firstID))
    let secondEndpoint = try runningEndpoint(await supervisor.state(for: secondID))
    XCTAssertNotEqual(firstEndpoint, secondEndpoint)
    XCTAssertEqual(Set([firstEndpoint.port, secondEndpoint.port]), Set([42001, 42002]))
    for directory in [firstDirectory, secondDirectory] {
      XCTAssertTrue(fileExists(directory.appendingPathComponent("Runtime/WORKFLOW.md")))
      XCTAssertTrue(fileExists(directory.appendingPathComponent("Workspaces")))
      XCTAssertTrue(fileExists(directory.appendingPathComponent("Logs/daemon.stdout.log")))
      XCTAssertTrue(fileExists(directory.appendingPathComponent("Logs/daemon.stderr.log")))
      let workflow = try String(
        contentsOf: directory.appendingPathComponent("Runtime/WORKFLOW.md"),
        encoding: .utf8
      )
      XCTAssertTrue(workflow.contains("kind: memory"))
      XCTAssertTrue(workflow.contains(directory.appendingPathComponent("Workspaces").path))
    }

    try await supervisor.stop(namespaceID: firstID)

    let stoppedState = await supervisor.state(for: firstID)
    let stillRunningEndpoint = try runningEndpoint(await supervisor.state(for: secondID))
    XCTAssertEqual(stoppedState, .stopped)
    XCTAssertEqual(stillRunningEndpoint, secondEndpoint)
    try await supervisor.stopAll()
  }

  func testRestartDoesNotAcceptTheOldProcessesDelayedTermination() async throws {
    let executable = try makeLongRunningExecutable()
    let ports = PortSequence([42101, 42102])
    let terminations = DeferredTerminationDelivery()
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: executable,
      readinessTimeout: 1,
      readinessProbe: { _ in true },
      portAllocator: { try ports.next() },
      terminationDelivery: { operation in
        terminations.defer(operation)
      }
    )
    let namespaceID = UUID()
    let directory = try makeNamespaceDirectory(namespaceID)
    await supervisor.start(namespaceID: namespaceID, namespaceDirectory: directory)

    try await supervisor.stop(namespaceID: namespaceID)
    await supervisor.start(namespaceID: namespaceID, namespaceDirectory: directory)
    try await terminations.waitForDeferredOperation()
    let deliveredCount = await terminations.deliverAll()

    let restartedState = await supervisor.state(for: namespaceID)
    XCTAssertGreaterThanOrEqual(deliveredCount, 1)
    XCTAssertEqual(restartedState, .running(endpoint: URL(string: "http://127.0.0.1:42102")!))
    try await supervisor.stopAll()
    _ = await terminations.deliverAll()
  }

  func testFailedDaemonCanRestartAndReachRunning() async throws {
    let namespaceID = UUID()
    let marker = temporaryDirectory.appendingPathComponent("first-launch")
    let executable = try makeExecutable(
      named: "fail-once",
      body: """
        if [ ! -e '\(marker.path)' ]; then
          touch '\(marker.path)'
          exit 7
        fi
        trap 'exit 0' TERM INT
        while :; do sleep 1; done
        """
    )
    let ports = PortSequence([42111, 42112])
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: executable,
      readinessTimeout: 1,
      readinessProbe: { endpoint in endpoint.port == 42112 },
      portAllocator: { try ports.next() }
    )
    let directory = try makeNamespaceDirectory(namespaceID)

    await supervisor.start(namespaceID: namespaceID, namespaceDirectory: directory)
    guard case .failed = await supervisor.state(for: namespaceID) else {
      return XCTFail("Expected the first start to fail")
    }

    try await supervisor.stop(namespaceID: namespaceID)
    await supervisor.start(namespaceID: namespaceID, namespaceDirectory: directory)

    let restartedState = await supervisor.state(for: namespaceID)
    XCTAssertEqual(restartedState, .running(endpoint: URL(string: "http://127.0.0.1:42112")!))
    try await supervisor.stopAll()
  }

  func testUnexpectedExitReportsFailureWithoutChangingAnotherNamespace() async throws {
    let stableID = UUID()
    let failedID = UUID()
    let executable = try makeExecutable(
      named: "selective-exit",
      body: """
        case "$*" in
          *\(failedID.uuidString)*) exit 7 ;;
        esac
        trap 'exit 0' TERM INT
        while :; do sleep 1; done
        """
    )
    let stableDirectory = try makeNamespaceDirectory(stableID)
    let failedDirectory = try makeNamespaceDirectory(failedID)
    let ports = PortSequence([42201, 42202])
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: executable,
      readinessTimeout: 1,
      readinessProbe: { endpoint in endpoint.port == 42201 },
      portAllocator: { try ports.next() }
    )
    await supervisor.start(namespaceID: stableID, namespaceDirectory: stableDirectory)

    await supervisor.start(namespaceID: failedID, namespaceDirectory: failedDirectory)

    let failure = await supervisor.state(for: failedID)
    guard case .failed(let message) = failure else {
      return XCTFail("Expected a failed daemon, got \(failure)")
    }
    XCTAssertTrue(message.contains("status 7") || message.contains("ready"))
    let stableState = await supervisor.state(for: stableID)
    XCTAssertEqual(stableState, .running(endpoint: URL(string: "http://127.0.0.1:42201")!))
    try await supervisor.stopAll()
  }

  func testStopAllStopsEveryNamespace() async throws {
    let executable = try makeLongRunningExecutable()
    let ports = PortSequence([42211, 42212])
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: executable,
      readinessTimeout: 1,
      readinessProbe: { _ in true },
      portAllocator: { try ports.next() }
    )
    let firstID = UUID()
    let secondID = UUID()
    await supervisor.start(
      namespaceID: firstID,
      namespaceDirectory: try makeNamespaceDirectory(firstID)
    )
    await supervisor.start(
      namespaceID: secondID,
      namespaceDirectory: try makeNamespaceDirectory(secondID)
    )

    try await supervisor.stopAll()

    let firstState = await supervisor.state(for: firstID)
    let secondState = await supervisor.state(for: secondID)
    XCTAssertEqual(firstState, .stopped)
    XCTAssertEqual(secondState, .stopped)
  }

  func testApplicationShutdownRejectsAStartThatArrivesWhileStopping() async throws {
    let readySignal = temporaryDirectory.appendingPathComponent("shutdown-ready")
    let stopSignal = temporaryDirectory.appendingPathComponent("shutdown-started")
    let executable = try makeExecutable(
      named: "slow-stop",
      body: """
        trap 'touch "\(stopSignal.path)"' TERM
        touch "\(readySignal.path)"
        while :; do sleep 0.02; done
        """
    )
    let ports = PortSequence([42221, 42222])
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: executable,
      readinessTimeout: 1,
      readinessProbe: { _ in FileManager.default.fileExists(atPath: readySignal.path) },
      portAllocator: { try ports.next() },
      gracefulStopTimeout: 1,
      forcedStopTimeout: 1
    )
    let runningID = UUID()
    let rejectedID = UUID()
    await supervisor.start(
      namespaceID: runningID,
      namespaceDirectory: try makeNamespaceDirectory(runningID)
    )

    let shutdown = Task {
      try await supervisor.shutdownForApplicationTermination()
    }
    try await waitForFile(stopSignal)
    await supervisor.start(
      namespaceID: rejectedID,
      namespaceDirectory: try makeNamespaceDirectory(rejectedID)
    )
    try await shutdown.value

    let runningState = await supervisor.state(for: runningID)
    let rejectedState = await supervisor.state(for: rejectedID)
    XCTAssertEqual(runningState, .stopped)
    XCTAssertEqual(rejectedState, .stopped)
    XCTAssertEqual(ports.requestCount, 1)
  }

  func testCancellingConcurrentStopDoesNotBlockTheOriginalStop() async throws {
    let readySignal = temporaryDirectory.appendingPathComponent("concurrent-stop-ready")
    let stopSignal = temporaryDirectory.appendingPathComponent("stop-started")
    let executable = try makeExecutable(
      named: "concurrent-stop",
      body: """
        trap 'touch "\(stopSignal.path)"' TERM
        touch "\(readySignal.path)"
        while :; do sleep 0.02; done
        """
    )
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: executable,
      readinessTimeout: 1,
      readinessProbe: { _ in FileManager.default.fileExists(atPath: readySignal.path) },
      portAllocator: { 42231 },
      gracefulStopTimeout: 1,
      forcedStopTimeout: 1
    )
    let namespaceID = UUID()
    await supervisor.start(
      namespaceID: namespaceID,
      namespaceDirectory: try makeNamespaceDirectory(namespaceID)
    )

    let originalStop = Task {
      try await supervisor.stop(namespaceID: namespaceID)
    }
    try await waitForFile(stopSignal)
    let waitingStop = Task {
      try await supervisor.stop(namespaceID: namespaceID)
    }
    await Task.yield()
    waitingStop.cancel()

    do {
      try await waitingStop.value
      XCTFail("Expected the waiting stop to be cancelled")
    } catch is CancellationError {
      // Cancellation is the expected contract for a waiting caller.
    }
    try await originalStop.value

    let state = await supervisor.state(for: namespaceID)
    XCTAssertEqual(state, .stopped)
  }

  func testMissingExecutableReportsAnActionableFailure() async throws {
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: nil,
      readinessTimeout: 0.1,
      readinessProbe: { _ in false },
      portAllocator: { 42301 }
    )
    let namespaceID = UUID()

    await supervisor.start(
      namespaceID: namespaceID,
      namespaceDirectory: try makeNamespaceDirectory(namespaceID)
    )

    let failedState = await supervisor.state(for: namespaceID)
    XCTAssertEqual(
      failedState,
      .failed(
        message: """
          The Symphony daemon executable could not be found. \
          Reinstall the application and try again.
          """
      )
    )
  }

  func testReadinessCleanupFailureRetainsOwnershipAndBlocksReplacement() async throws {
    let pidFile = temporaryDirectory.appendingPathComponent("daemon.pid")
    let executable = try makeExecutable(
      named: "unstoppable",
      body: """
        echo $$ > '\(pidFile.path)'
        trap '' TERM
        while :; do sleep 1; done
        """
    )
    let ports = PortSequence([42311, 42312])
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: executable,
      readinessTimeout: 0.01,
      readinessProbe: { _ in false },
      portAllocator: { try ports.next() },
      gracefulStopTimeout: 0.01,
      forcedStopTimeout: 0.01,
      forceKill: { _ in -1 }
    )
    let namespaceID = UUID()
    let directory = try makeNamespaceDirectory(namespaceID)

    await supervisor.start(namespaceID: namespaceID, namespaceDirectory: directory)
    let failedState = await supervisor.state(for: namespaceID)
    XCTAssertEqual(
      failedState,
      .failed(
        message: """
          The Symphony daemon could not be stopped safely. \
          Try again before deleting or locking the namespace.
          """
      )
    )

    await supervisor.start(namespaceID: namespaceID, namespaceDirectory: directory)

    let retainedState = await supervisor.state(for: namespaceID)
    let portRequests = ports.requestCount
    XCTAssertEqual(retainedState, failedState)
    XCTAssertEqual(portRequests, 1)
    do {
      try await supervisor.stopAll()
      XCTFail("Expected stop-all failure")
    } catch let error as NamespaceDaemonStopAllError {
      XCTAssertNotNil(error.failures[namespaceID])
    }

    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try XCTUnwrap(Int32(pidText))
    Darwin.kill(pid, SIGKILL)
  }

  private func makeNamespaceDirectory(_ id: UUID) throws -> URL {
    let directory = temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeLongRunningExecutable() throws -> URL {
    try makeExecutable(
      named: "long-running-\(UUID().uuidString)",
      body: "trap 'exit 0' TERM INT\nwhile :; do sleep 1; done"
    )
  }

  private func makeExecutable(named name: String, body: String) throws -> URL {
    let url = temporaryDirectory.appendingPathComponent(name)
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  private func waitForFile(_ url: URL) async throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if fileExists(url) {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.fileDidNotAppear(url)
  }

  private func runningEndpoint(_ state: NamespaceDaemonState) throws -> URL {
    guard case .running(let endpoint) = state else {
      throw TestFailure.expectedRunning(state)
    }
    return endpoint
  }
}

private enum TestFailure: Error {
  case expectedRunning(NamespaceDaemonState)
  case fileDidNotAppear(URL)
  case terminationWasNotDeferred
}

private final class PortSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var ports: [UInt16]
  private var requests = 0

  init(_ ports: [UInt16]) {
    self.ports = ports
  }

  func next() throws -> UInt16 {
    try lock.withLock {
      requests += 1
      guard !ports.isEmpty else {
        throw NamespaceDaemonError.endpointUnavailable
      }
      return ports.removeFirst()
    }
  }

  var requestCount: Int {
    lock.withLock { requests }
  }
}

private final class DeferredTerminationDelivery: @unchecked Sendable {
  typealias Operation = @Sendable () async -> Void

  private let lock = NSLock()
  private var operations: [Operation] = []

  func `defer`(_ operation: @escaping Operation) {
    lock.withLock {
      operations.append(operation)
    }
  }

  func waitForDeferredOperation() async throws {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      if lock.withLock({ !operations.isEmpty }) {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.terminationWasNotDeferred
  }

  func deliverAll() async -> Int {
    let deferred = lock.withLock {
      let deferred = operations
      operations.removeAll()
      return deferred
    }
    for operation in deferred {
      await operation()
    }
    return deferred.count
  }
}
