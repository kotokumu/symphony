import Foundation
import SymphonyDesktopCore
import SymphonyDesktopInfrastructure
import XCTest

final class CodexAuthenticationManagerTests: XCTestCase {
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
    let executor = RecordingCodexCommandExecutor()
    let namespaceID = UUID()
    let namespaceDirectory = temporaryDirectory
    await executor.enqueue(.init(status: 0, output: "Logged in using ChatGPT"))

    let recreatedManager = CodexAuthenticationManager(executor: executor)
    await recreatedManager.refresh(
      namespaceID: namespaceID,
      namespaceDirectory: namespaceDirectory
    )

    let invocations = await executor.recordedInvocations()
    let invocation = try XCTUnwrap(invocations.first)
    XCTAssertEqual(
      invocation.codexHome,
      namespaceDirectory.appendingPathComponent("CodexHome", isDirectory: true)
    )
    let state = await recreatedManager.state(for: namespaceID)
    XCTAssertEqual(state, .signedIn)
  }

  private var temporaryDirectory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-auth-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
