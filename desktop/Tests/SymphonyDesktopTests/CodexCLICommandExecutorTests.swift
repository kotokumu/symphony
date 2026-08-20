import Darwin
import Foundation
import SymphonyDesktopInfrastructure
import XCTest

final class CodexCLICommandExecutorTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  func testSuppliesOnlyTheNamespaceCodexHomeAndRemovesInheritedCredentials() async throws {
    let executor = CodexCLICommandExecutor(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      environment: [
        "PATH": "/usr/bin:/bin",
        "CODEX_HOME": "/global/codex-home",
        "OPENAI_API_KEY": "inherited-openai-key",
        "CODEX_ACCESS_TOKEN": "inherited-access-token",
        "CODEX_API_KEY": "inherited-codex-key",
      ]
    )
    let codexHome = temporaryDirectory.appendingPathComponent("CodexHome")

    let result = try await executor.execute(
      CodexCommandInvocation(arguments: [], codexHome: codexHome)
    )

    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("CODEX_HOME=\(codexHome.path)"))
    XCTAssertFalse(result.output.contains("/global/codex-home"))
    XCTAssertFalse(result.output.contains("inherited-openai-key"))
    XCTAssertFalse(result.output.contains("inherited-access-token"))
    XCTAssertFalse(result.output.contains("inherited-codex-key"))
    let attributes = try FileManager.default.attributesOfItem(atPath: codexHome.path)
    XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
  }

  func testReportsAnUnavailableExecutableWithoutCreatingCodexHome() async throws {
    let codexHome = temporaryDirectory.appendingPathComponent("CodexHome")
    let executor = CodexCLICommandExecutor(executableURL: nil)

    do {
      _ = try await executor.execute(
        CodexCommandInvocation(arguments: ["login", "status"], codexHome: codexHome)
      )
      XCTFail("Expected the missing executable to fail")
    } catch let error as CodexCLIError {
      XCTAssertEqual(
        error.localizedDescription,
        "The Codex CLI could not be found. Install Codex and try again."
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: codexHome.path))
  }

  func testCancellationWaitsForATermCooperativeProcessToExit() async throws {
    let executable = try makeBlockingExecutable(ignoresTerm: false)
    let codexHome = temporaryDirectory.appendingPathComponent("cooperative", isDirectory: true)
    let executor = CodexCLICommandExecutor(
      executableURL: executable,
      gracefulStopTimeout: 0.5,
      forcedStopTimeout: 0.5
    )
    let command = Task {
      try await executor.execute(CodexCommandInvocation(arguments: [], codexHome: codexHome))
    }
    await waitForFile(codexHome.appendingPathComponent("ready"))

    command.cancel()
    do {
      _ = try await command.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("terminated").path))
    try assertRecordedProcessExited(in: codexHome)
  }

  func testCancellationForceKillsATermIgnoringProcessWithinTheDeadline() async throws {
    let executable = try makeBlockingExecutable(ignoresTerm: true)
    let codexHome = temporaryDirectory.appendingPathComponent("forced", isDirectory: true)
    let executor = CodexCLICommandExecutor(
      executableURL: executable,
      gracefulStopTimeout: 0.05,
      forcedStopTimeout: 0.5
    )
    let command = Task {
      try await executor.execute(CodexCommandInvocation(arguments: [], codexHome: codexHome))
    }
    await waitForFile(codexHome.appendingPathComponent("ready"))
    let startedStopping = Date()

    command.cancel()
    do {
      _ = try await command.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }

    XCTAssertLessThan(Date().timeIntervalSince(startedStopping), 1)
    try assertRecordedProcessExited(in: codexHome)
  }

  func testCancellationReportsWhenForcedTerminationCannotBeDelivered() async throws {
    let executable = try makeBlockingExecutable(ignoresTerm: true)
    let codexHome = temporaryDirectory.appendingPathComponent("undeliverable", isDirectory: true)
    let forceKill = FailOnceForceKill()
    let executor = CodexCLICommandExecutor(
      executableURL: executable,
      gracefulStopTimeout: 0.05,
      forcedStopTimeout: 0.05,
      forceKill: { processIdentifier in
        forceKill.deliver(to: processIdentifier)
      }
    )
    let command = Task {
      try await executor.execute(CodexCommandInvocation(arguments: [], codexHome: codexHome))
    }
    await waitForFile(codexHome.appendingPathComponent("ready"))

    command.cancel()
    do {
      _ = try await command.value
      XCTFail("Expected stop failure")
    } catch CodexCLIError.stopFailed {
    }

    let processIdentifier = try recordedProcessIdentifier(in: codexHome)
    XCTAssertEqual(Darwin.kill(processIdentifier, 0), 0)
    do {
      _ = try await executor.execute(
        CodexCommandInvocation(arguments: [], codexHome: codexHome)
      )
      XCTFail("Expected the retained process to block replacement")
    } catch CodexCLIError.commandAlreadyRunning {
    }

    try await executor.stop(codexHome: codexHome)
    await waitForProcessExit(processIdentifier)
    XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
  }

  private func makeBlockingExecutable(ignoresTerm: Bool) throws -> URL {
    let executable = temporaryDirectory.appendingPathComponent(
      ignoresTerm ? "ignore-term" : "handle-term"
    )
    let trap =
      ignoresTerm
      ? "trap '' TERM"
      : "trap 'touch \"$CODEX_HOME/terminated\"; exit 0' TERM"
    let script = """
      #!/bin/sh
      \(trap)
      echo $$ > "$CODEX_HOME/pid"
      touch "$CODEX_HOME/ready"
      while :; do
        sleep 0.05
      done
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
  }

  private func waitForFile(_ url: URL, timeout: TimeInterval = 2) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  private func recordedProcessIdentifier(in codexHome: URL) throws -> Int32 {
    let value = try String(
      contentsOf: codexHome.appendingPathComponent("pid"),
      encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return try XCTUnwrap(Int32(value))
  }

  private func assertRecordedProcessExited(in codexHome: URL) throws {
    let processIdentifier = try recordedProcessIdentifier(in: codexHome)
    XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
  }

  private func waitForProcessExit(_ processIdentifier: Int32) async {
    let deadline = Date().addingTimeInterval(1)
    while Darwin.kill(processIdentifier, 0) == 0, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}

private final class FailOnceForceKill: @unchecked Sendable {
  private let lock = NSLock()
  private var deliveryCount = 0

  func deliver(to processIdentifier: Int32) -> Int32 {
    lock.lock()
    deliveryCount += 1
    let shouldFail = deliveryCount == 1
    lock.unlock()
    return shouldFail ? -1 : Darwin.kill(processIdentifier, SIGKILL)
  }
}
