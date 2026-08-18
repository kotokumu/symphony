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
    let ports = PortSequence([42001, 42002])
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

    XCTAssertEqual(await supervisor.state(for: firstID), .stopped)
    XCTAssertEqual(try runningEndpoint(await supervisor.state(for: secondID)), secondEndpoint)
    await supervisor.stopAll()
  }

  func testRestartDoesNotAcceptTheOldProcessesDelayedTermination() async throws {
    let executable = try makeLongRunningExecutable()
    let ports = PortSequence([42101, 42102])
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: executable,
      readinessTimeout: 1,
      readinessProbe: { _ in true },
      portAllocator: { try ports.next() }
    )
    let namespaceID = UUID()
    let directory = try makeNamespaceDirectory(namespaceID)
    await supervisor.start(namespaceID: namespaceID, namespaceDirectory: directory)

    try await supervisor.stop(namespaceID: namespaceID)
    await supervisor.start(namespaceID: namespaceID, namespaceDirectory: directory)
    try? await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(
      await supervisor.state(for: namespaceID),
      .running(endpoint: URL(string: "http://127.0.0.1:42102")!)
    )
    await supervisor.stopAll()
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
    XCTAssertEqual(
      await supervisor.state(for: stableID),
      .running(endpoint: URL(string: "http://127.0.0.1:42201")!)
    )
    await supervisor.stopAll()
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

    XCTAssertEqual(
      await supervisor.state(for: namespaceID),
      .failed(
        message: """
          The Symphony daemon executable could not be found. \
          Reinstall the application and try again.
          """
      )
    )
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

  private func runningEndpoint(_ state: NamespaceDaemonState) throws -> URL {
    guard case .running(let endpoint) = state else {
      throw TestFailure.expectedRunning(state)
    }
    return endpoint
  }
}

private enum TestFailure: Error {
  case expectedRunning(NamespaceDaemonState)
}

private final class PortSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var ports: [UInt16]

  init(_ ports: [UInt16]) {
    self.ports = ports
  }

  func next() throws -> UInt16 {
    try lock.withLock {
      guard !ports.isEmpty else {
        throw NamespaceDaemonError.endpointUnavailable
      }
      return ports.removeFirst()
    }
  }
}
