import Foundation
import SymphonyDesktopCore
import SymphonyDesktopInfrastructure
import XCTest

final class CodexAuthenticationManagerTests: XCTestCase {
  private var testDirectory: URL!

  override func setUpWithError() throws {
    testDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-auth-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let testDirectory {
      try? FileManager.default.removeItem(at: testDirectory)
    }
  }

  func testUsesAnIndependentCodexHomeForEveryNamespace() async throws {
    let executor = RecordingCodexCommandExecutor()
    let manager = CodexAuthenticationManager(executor: executor)
    let firstID = UUID()
    let secondID = UUID()
    let firstDirectory = temporaryDirectory.appendingPathComponent("first")
    let secondDirectory = temporaryDirectory.appendingPathComponent("second")

    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))
    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))

    await manager.refresh(namespaceID: firstID, namespaceDirectory: firstDirectory)
    await manager.refresh(namespaceID: secondID, namespaceDirectory: secondDirectory)

    let invocations = await executor.recordedInvocations()
    XCTAssertEqual(invocations.map(\.arguments), [["login", "status"], ["login", "status"]])
    XCTAssertEqual(
      invocations[0].codexHome,
      firstDirectory.appendingPathComponent("CodexHome", isDirectory: true)
    )
    XCTAssertEqual(
      invocations[1].codexHome,
      secondDirectory.appendingPathComponent("CodexHome", isDirectory: true)
    )
    XCTAssertNotEqual(invocations[0].codexHome, invocations[1].codexHome)
    let firstState = await manager.state(for: firstID)
    let secondState = await manager.state(for: secondID)
    XCTAssertEqual(firstState, .signedIn)
    XCTAssertEqual(secondState, .signedIn)
  }

  func testBrowserLoginPublishesAuthenticatingThenSignedIn() async throws {
    let executor = RecordingCodexCommandExecutor()
    let manager = CodexAuthenticationManager(executor: executor)
    let namespaceID = UUID()
    let events = await manager.events()
    var iterator = events.makeAsyncIterator()

    await executor.enqueue(.init(status: 0, output: "Login successful"))
    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))

    await manager.signIn(namespaceID: namespaceID, namespaceDirectory: temporaryDirectory)

    let authenticatingEvent = await iterator.next()
    let signedInEvent = await iterator.next()
    XCTAssertEqual(
      authenticatingEvent,
      CodexAuthenticationEvent(namespaceID: namespaceID, state: .authenticating)
    )
    XCTAssertEqual(
      signedInEvent,
      CodexAuthenticationEvent(namespaceID: namespaceID, state: .signedIn)
    )
    let invocations = await executor.recordedInvocations()
    XCTAssertEqual(invocations.map(\.arguments), [["login"], ["login", "status"]])
  }

  func testLogoutOnlyChangesTheRequestedNamespace() async throws {
    let executor = RecordingCodexCommandExecutor()
    let manager = CodexAuthenticationManager(executor: executor)
    let firstID = UUID()
    let secondID = UUID()

    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))
    await manager.refresh(namespaceID: firstID, namespaceDirectory: temporaryDirectory)
    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))
    await manager.refresh(namespaceID: secondID, namespaceDirectory: temporaryDirectory)
    await executor.enqueue(.init(status: 0, output: "Logged out"))

    await manager.signOut(namespaceID: firstID, namespaceDirectory: temporaryDirectory)

    let firstState = await manager.state(for: firstID)
    let secondState = await manager.state(for: secondID)
    XCTAssertEqual(firstState, .signedOut)
    XCTAssertEqual(secondState, .signedIn)
  }

  func testRefreshDistinguishesSignedOutExpiredAndRecoverableFailure() async throws {
    let executor = RecordingCodexCommandExecutor()
    let manager = CodexAuthenticationManager(executor: executor)
    let signedOutID = UUID()
    let expiredID = UUID()
    let failedID = UUID()

    await executor.enqueue(.init(status: 1, output: "Not logged in"))
    await manager.refresh(namespaceID: signedOutID, namespaceDirectory: temporaryDirectory)
    await executor.enqueue(.init(status: 1, output: "Authentication expired. Sign in again."))
    await manager.refresh(namespaceID: expiredID, namespaceDirectory: temporaryDirectory)
    await executor.enqueue(.init(status: 2, output: "credential store unavailable"))
    await manager.refresh(namespaceID: failedID, namespaceDirectory: temporaryDirectory)

    let signedOutState = await manager.state(for: signedOutID)
    let expiredState = await manager.state(for: expiredID)
    let failedState = await manager.state(for: failedID)
    XCTAssertEqual(signedOutState, .signedOut)
    XCTAssertEqual(
      expiredState,
      .expired(message: "Authentication expired. Sign in again.")
    )
    XCTAssertEqual(
      failedState,
      .failed(message: "Codex authentication could not be checked: credential store unavailable")
    )

    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))
    await manager.refresh(namespaceID: failedID, namespaceDirectory: temporaryDirectory)
    await executor.enqueue(.init(status: 0, output: "Login successful"))
    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))
    await manager.signIn(namespaceID: expiredID, namespaceDirectory: temporaryDirectory)
    let recoveredRefreshState = await manager.state(for: failedID)
    let recoveredExpiredState = await manager.state(for: expiredID)
    XCTAssertEqual(recoveredRefreshState, .signedIn)
    XCTAssertEqual(recoveredExpiredState, .signedIn)
  }

  func testFailedLoginCanBeRetried() async throws {
    let executor = RecordingCodexCommandExecutor()
    let manager = CodexAuthenticationManager(executor: executor)
    let namespaceID = UUID()

    await executor.enqueue(.init(status: 1, output: "Browser login was cancelled"))
    await manager.signIn(namespaceID: namespaceID, namespaceDirectory: temporaryDirectory)
    let failedState = await manager.state(for: namespaceID)
    XCTAssertEqual(
      failedState,
      .failed(message: "Codex sign-in failed: Browser login was cancelled")
    )

    await executor.enqueue(.init(status: 0, output: "Login successful"))
    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))
    await manager.signIn(namespaceID: namespaceID, namespaceDirectory: temporaryDirectory)
    let recoveredState = await manager.state(for: namespaceID)
    XCTAssertEqual(recoveredState, .signedIn)
  }

  func testARecreatedManagerRestoresStateFromTheSameCodexHome() async throws {
    let executable = try makeStatefulCodexExecutable()
    let namespaceID = UUID()
    let namespaceDirectory = temporaryDirectory
    let firstManager = CodexAuthenticationManager(
      executor: CodexCLICommandExecutor(executableURL: executable)
    )
    await firstManager.signIn(
      namespaceID: namespaceID,
      namespaceDirectory: namespaceDirectory
    )

    let recreatedManager = CodexAuthenticationManager(
      executor: CodexCLICommandExecutor(executableURL: executable)
    )
    await recreatedManager.refresh(
      namespaceID: namespaceID,
      namespaceDirectory: namespaceDirectory
    )

    let state = await recreatedManager.state(for: namespaceID)
    XCTAssertEqual(state, .signedIn)
  }

  func testLogoutFailureHasARecoverableSignInPath() async throws {
    let executor = RecordingCodexCommandExecutor()
    let manager = CodexAuthenticationManager(executor: executor)
    let namespaceID = UUID()
    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))
    await manager.refresh(namespaceID: namespaceID, namespaceDirectory: temporaryDirectory)
    await executor.enqueue(.init(status: 1, output: "Credential store is busy"))

    await manager.signOut(namespaceID: namespaceID, namespaceDirectory: temporaryDirectory)

    let failedState = await manager.state(for: namespaceID)
    XCTAssertEqual(
      failedState,
      .failed(message: "Codex sign-out failed: Credential store is busy")
    )
    await executor.enqueue(.init(status: 0, output: "Login successful"))
    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))
    await manager.signIn(namespaceID: namespaceID, namespaceDirectory: temporaryDirectory)
    let recoveredState = await manager.state(for: namespaceID)
    XCTAssertEqual(recoveredState, .signedIn)
  }

  func testStatefulLogoutDoesNotChangeAnotherNamespace() async throws {
    let executable = try makeStatefulCodexExecutable()
    let firstID = UUID()
    let secondID = UUID()
    let firstDirectory = temporaryDirectory.appendingPathComponent("first", isDirectory: true)
    let secondDirectory = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
    let manager = CodexAuthenticationManager(
      executor: CodexCLICommandExecutor(executableURL: executable)
    )
    await manager.signIn(namespaceID: firstID, namespaceDirectory: firstDirectory)
    await manager.signIn(namespaceID: secondID, namespaceDirectory: secondDirectory)

    await manager.signOut(namespaceID: firstID, namespaceDirectory: firstDirectory)

    let recreatedManager = CodexAuthenticationManager(
      executor: CodexCLICommandExecutor(executableURL: executable)
    )
    async let firstRefresh: Void = recreatedManager.refresh(
      namespaceID: firstID,
      namespaceDirectory: firstDirectory
    )
    async let secondRefresh: Void = recreatedManager.refresh(
      namespaceID: secondID,
      namespaceDirectory: secondDirectory
    )
    _ = await (firstRefresh, secondRefresh)
    let firstState = await recreatedManager.state(for: firstID)
    let secondState = await recreatedManager.state(for: secondID)
    XCTAssertEqual(firstState, .signedOut)
    XCTAssertEqual(secondState, .signedIn)
  }

  func testBrowserLoginWaitsForCallbackThenReturnsSignedIn() async throws {
    let executable = try makeStatefulCodexExecutable()
    let namespaceID = UUID()
    let namespaceDirectory = temporaryDirectory.appendingPathComponent(
      "callback", isDirectory: true)
    let codexHome = namespaceDirectory.appendingPathComponent("CodexHome", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    _ = FileManager.default.createFile(
      atPath: codexHome.appendingPathComponent("require-callback").path,
      contents: Data()
    )
    let manager = CodexAuthenticationManager(
      executor: CodexCLICommandExecutor(executableURL: executable)
    )
    let completion = CompletionFlag()
    let signIn = Task {
      await manager.signIn(namespaceID: namespaceID, namespaceDirectory: namespaceDirectory)
      await completion.markComplete()
    }
    await waitForFile(codexHome.appendingPathComponent("waiting-for-callback"))
    let authenticatingState = await manager.state(for: namespaceID)
    XCTAssertEqual(authenticatingState, .authenticating)
    let completedBeforeCallback = await completion.isComplete()
    XCTAssertFalse(completedBeforeCallback)

    _ = FileManager.default.createFile(
      atPath: codexHome.appendingPathComponent("callback-complete").path,
      contents: Data()
    )
    await signIn.value

    let state = await manager.state(for: namespaceID)
    XCTAssertEqual(state, .signedIn)
  }

  func testNamespaceQuiescenceDrainsAndRejectsOnlyThatNamespacesOperations() async throws {
    let executor = GatedCodexCommandExecutor()
    let firstID = UUID()
    let secondID = UUID()
    let firstDirectory = temporaryDirectory.appendingPathComponent("quiesced", isDirectory: true)
    let secondDirectory = temporaryDirectory.appendingPathComponent(
      "independent", isDirectory: true)
    let firstHome = firstDirectory.appendingPathComponent("CodexHome", isDirectory: true)
    await executor.block(firstHome)
    let manager = CodexAuthenticationManager(executor: executor)
    let firstSignIn = Task {
      await manager.signIn(namespaceID: firstID, namespaceDirectory: firstDirectory)
    }
    await waitUntil {
      await executor.executionCount(for: firstHome) == 1
    }

    await manager.signIn(namespaceID: secondID, namespaceDirectory: secondDirectory)
    try await manager.quiesce(namespaceID: firstID)
    await firstSignIn.value
    await manager.signIn(namespaceID: firstID, namespaceDirectory: firstDirectory)

    let rejectedCount = await executor.executionCount(for: firstHome)
    let secondState = await manager.state(for: secondID)
    XCTAssertEqual(rejectedCount, 1)
    XCTAssertEqual(secondState, .signedIn)

    await executor.unblock(firstHome)
    await manager.resume(namespaceID: firstID)
    await manager.signIn(namespaceID: firstID, namespaceDirectory: firstDirectory)
    let resumedState = await manager.state(for: firstID)
    XCTAssertEqual(resumedState, .signedIn)
  }

  func testApplicationShutdownDrainsAllNamespacesAndRejectsNewOperations() async throws {
    let executor = GatedCodexCommandExecutor()
    let firstID = UUID()
    let secondID = UUID()
    let firstDirectory = temporaryDirectory.appendingPathComponent(
      "shutdown-first", isDirectory: true)
    let secondDirectory = temporaryDirectory.appendingPathComponent(
      "shutdown-second", isDirectory: true)
    let firstHome = firstDirectory.appendingPathComponent("CodexHome", isDirectory: true)
    let secondHome = secondDirectory.appendingPathComponent("CodexHome", isDirectory: true)
    await executor.block(firstHome)
    await executor.block(secondHome)
    let manager = CodexAuthenticationManager(executor: executor)
    let firstSignIn = Task {
      await manager.signIn(namespaceID: firstID, namespaceDirectory: firstDirectory)
    }
    let secondSignIn = Task {
      await manager.signIn(namespaceID: secondID, namespaceDirectory: secondDirectory)
    }
    await waitUntil {
      let firstCount = await executor.executionCount(for: firstHome)
      let secondCount = await executor.executionCount(for: secondHome)
      return firstCount == 1 && secondCount == 1
    }

    try await manager.shutdownForApplicationTermination()
    await firstSignIn.value
    await secondSignIn.value
    await manager.signIn(namespaceID: firstID, namespaceDirectory: firstDirectory)
    let rejectedCount = await executor.executionCount(for: firstHome)
    XCTAssertEqual(rejectedCount, 1)

    await executor.unblock(firstHome)
    await manager.resumeAfterApplicationTerminationFailure()
    await manager.signIn(namespaceID: firstID, namespaceDirectory: firstDirectory)
    let resumedState = await manager.state(for: firstID)
    XCTAssertEqual(resumedState, .signedIn)
  }

  func testFailedStopRetainsOwnershipAndASecondQuiesceRetriesCleanup() async throws {
    let executor = RetainingStopFailureExecutor()
    let manager = CodexAuthenticationManager(executor: executor)
    let namespaceID = UUID()
    let namespaceDirectory = temporaryDirectory.appendingPathComponent(
      "stop-retry", isDirectory: true)
    let signIn = Task {
      await manager.signIn(namespaceID: namespaceID, namespaceDirectory: namespaceDirectory)
    }
    await waitUntil {
      await executor.executionCount() == 1
    }

    do {
      try await manager.quiesce(namespaceID: namespaceID)
      XCTFail("Expected the first stop to fail")
    } catch CodexAuthenticationLifecycleError.stopFailed {
    }
    await signIn.value
    await manager.signIn(namespaceID: namespaceID, namespaceDirectory: namespaceDirectory)
    let replacementCount = await executor.executionCount()
    XCTAssertEqual(replacementCount, 1)

    try await manager.quiesce(namespaceID: namespaceID)

    let stopAttempts = await executor.stopAttemptCount()
    XCTAssertEqual(stopAttempts, 2)
  }

  private func makeStatefulCodexExecutable() throws -> URL {
    let executable = testDirectory.appendingPathComponent("fake-codex")
    let script = """
      #!/bin/sh
      state="$CODEX_HOME/authenticated"
      if [ "$1" = "login" ] && [ "${2:-}" = "status" ]; then
        if [ -f "$state" ]; then
          echo "Logged in using ChatGPT"
          exit 0
        fi
        echo "Not logged in"
        exit 1
      fi
      if [ "$1" = "login" ]; then
        if [ -f "$CODEX_HOME/require-callback" ]; then
          touch "$CODEX_HOME/waiting-for-callback"
          while [ ! -f "$CODEX_HOME/callback-complete" ]; do
            sleep 0.05
          done
        fi
        touch "$state"
        echo "Login successful"
        exit 0
      fi
      if [ "$1" = "logout" ]; then
        rm -f "$state"
        echo "Logged out"
        exit 0
      fi
      exit 64
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping () async -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let conditionSatisfied = await condition()
    XCTAssertTrue(conditionSatisfied)
  }

  private func waitForFile(_ url: URL, timeout: TimeInterval = 2) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  private var temporaryDirectory: URL {
    testDirectory
  }
}

private actor CompletionFlag {
  private var complete = false

  func markComplete() {
    complete = true
  }

  func isComplete() -> Bool {
    complete
  }
}

private actor GatedCodexCommandExecutor: CodexCommandExecuting {
  private var blockedHomes: Set<URL> = []
  private var counts: [URL: Int] = [:]

  func block(_ codexHome: URL) {
    blockedHomes.insert(codexHome)
  }

  func unblock(_ codexHome: URL) {
    blockedHomes.remove(codexHome)
  }

  func execute(_ invocation: CodexCommandInvocation) async throws -> CodexCommandResult {
    counts[invocation.codexHome, default: 0] += 1
    if blockedHomes.contains(invocation.codexHome) {
      try await Task.sleep(for: .seconds(60))
    }
    if invocation.arguments == ["login", "status"] {
      return CodexCommandResult(status: 0, output: "Logged in using ChatGPT")
    }
    return CodexCommandResult(status: 0, output: "Login successful")
  }

  func executionCount(for codexHome: URL) -> Int {
    counts[codexHome, default: 0]
  }
}

private actor RetainingStopFailureExecutor: CodexCommandExecuting {
  private var executions = 0
  private var stopAttempts = 0

  func execute(_ invocation: CodexCommandInvocation) async throws -> CodexCommandResult {
    executions += 1
    do {
      try await Task.sleep(for: .seconds(60))
      return CodexCommandResult(status: 0, output: "Login successful")
    } catch is CancellationError {
      throw CodexCLIError.stopFailed
    }
  }

  func stop(codexHome: URL) async throws {
    stopAttempts += 1
    if stopAttempts == 1 {
      throw CodexCLIError.stopFailed
    }
  }

  func executionCount() -> Int {
    executions
  }

  func stopAttemptCount() -> Int {
    stopAttempts
  }
}

private actor RecordingCodexCommandExecutor: CodexCommandExecuting {
  private var results: [CodexCommandResult] = []
  private var invocations: [CodexCommandInvocation] = []

  func enqueue(_ result: CodexCommandResult) {
    results.append(result)
  }

  func execute(_ invocation: CodexCommandInvocation) throws -> CodexCommandResult {
    invocations.append(invocation)
    guard !results.isEmpty else {
      throw TestCommandError.missingResult
    }
    return results.removeFirst()
  }

  func recordedInvocations() -> [CodexCommandInvocation] {
    invocations
  }
}

private enum TestCommandError: Error {
  case missingResult
}
