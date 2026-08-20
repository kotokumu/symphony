import Foundation
import SymphonyDesktopCore
import XCTest

@testable import SymphonyDesktop

@MainActor
final class CodexAuthenticationControllerTests: XCTestCase {
  func testProjectsAuthenticationEventsByNamespace() async throws {
    let authenticator = TestCodexAuthenticator()
    let controller = CodexAuthenticationController(
      authenticator: authenticator,
      directoryURL: { id in URL(fileURLWithPath: "/namespaces/\(id)") }
    )
    let firstID = UUID()
    let secondID = UUID()
    await controller.startObserving()

    await authenticator.emit(
      .init(namespaceID: firstID, state: .authenticating)
    )
    await authenticator.emit(
      .init(namespaceID: secondID, state: .signedIn)
    )
    await eventually {
      controller.state(for: firstID) == .authenticating
        && controller.state(for: secondID) == .signedIn
    }
  }

  func testRoutesCommandsToTheStableNamespaceDirectory() async throws {
    let authenticator = TestCodexAuthenticator()
    let namespaceID = UUID()
    let directory = URL(fileURLWithPath: "/namespaces/\(namespaceID)")
    let controller = CodexAuthenticationController(
      authenticator: authenticator,
      directoryURL: { _ in directory }
    )

    await controller.refresh(namespaceID)
    await controller.signIn(namespaceID)
    await controller.signOut(namespaceID)

    let commands = await authenticator.recordedCommands()
    XCTAssertEqual(
      commands,
      [
        .refresh(namespaceID, directory),
        .signIn(namespaceID, directory),
        .signOut(namespaceID, directory),
      ]
    )
  }

  func testCancelsAnActiveBrowserLoginBeforeNamespaceDataIsRemoved() async throws {
    let authenticator = TestCodexAuthenticator()
    await authenticator.setBlocksSignIn(true)
    let namespaceID = UUID()
    let controller = CodexAuthenticationController(
      authenticator: authenticator,
      directoryURL: { _ in URL(fileURLWithPath: "/namespaces/auth") }
    )
    let signIn = Task {
      await controller.signIn(namespaceID)
    }
    let deadline = Date().addingTimeInterval(1)
    while !(await authenticator.didStartSignIn()), Date() < deadline {
      await Task.yield()
    }

    await controller.cancel(namespaceID)
    await signIn.value

    let wasCancelled = await authenticator.wasSignInCancelled()
    XCTAssertTrue(wasCancelled)
  }

  private func eventually(
    timeout: TimeInterval = 1,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      await Task.yield()
    }
    XCTAssertTrue(condition())
  }
}

private actor TestCodexAuthenticator: CodexAuthenticating {
  enum Command: Equatable {
    case refresh(UUID, URL)
    case signIn(UUID, URL)
    case signOut(UUID, URL)
  }

  private var continuation: AsyncStream<CodexAuthenticationEvent>.Continuation?
  private var commands: [Command] = []
  private var blocksSignIn = false
  private var signInStarted = false
  private var signInCancelled = false

  func events() -> AsyncStream<CodexAuthenticationEvent> {
    AsyncStream { continuation in
      self.continuation = continuation
    }
  }

  func refresh(namespaceID: UUID, namespaceDirectory: URL) {
    commands.append(.refresh(namespaceID, namespaceDirectory))
  }

  func signIn(namespaceID: UUID, namespaceDirectory: URL) async {
    commands.append(.signIn(namespaceID, namespaceDirectory))
    guard blocksSignIn else {
      return
    }
    signInStarted = true
    do {
      try await Task.sleep(for: .seconds(60))
    } catch {
      signInCancelled = true
    }
  }

  func signOut(namespaceID: UUID, namespaceDirectory: URL) {
    commands.append(.signOut(namespaceID, namespaceDirectory))
  }

  func emit(_ event: CodexAuthenticationEvent) {
    continuation?.yield(event)
  }

  func recordedCommands() -> [Command] {
    commands
  }

  func setBlocksSignIn(_ value: Bool) {
    blocksSignIn = value
  }

  func didStartSignIn() -> Bool {
    signInStarted
  }

  func wasSignInCancelled() -> Bool {
    signInCancelled
  }
}
