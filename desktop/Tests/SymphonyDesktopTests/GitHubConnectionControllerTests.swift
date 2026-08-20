import Foundation
import XCTest

@testable import SymphonyCredentialBrokerProtocol
@testable import SymphonyDesktop
@testable import SymphonyDesktopCore

@MainActor
final class GitHubConnectionControllerTests: XCTestCase {
  func testConnectsOneNamespaceThroughInstallationAndRepositorySelection() async throws {
    let namespaceID = UUID()
    let broker = RecordingGitHubConnectionBroker()
    let controller = GitHubConnectionController(
      broker: broker,
      credentialCleanup: RecordingGitHubCredentialCleanup()
    )
    let keyURL = URL(fileURLWithPath: "/private/github-app.pem")

    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: keyURL
    )
    guard case .choosingInstallation(let appID, let installations) = controller.state(
      for: namespaceID
    ) else {
      return XCTFail("Expected installation selection")
    }
    XCTAssertEqual(appID, 10)

    await controller.chooseInstallation(try XCTUnwrap(installations.first), namespaceID: namespaceID)
    guard case .choosingRepository(_, _, let repositories) = controller.state(for: namespaceID)
    else {
      return XCTFail("Expected repository selection")
    }
    var saved: GitHubConnection?
    try await controller.connect(
      try XCTUnwrap(repositories.first),
      namespaceID: namespaceID,
      save: { saved = $0 }
    )

    XCTAssertEqual(saved?.repositoryFullName, "octo/research")
    XCTAssertEqual(controller.state(for: namespaceID), .idle)
    let configured = await broker.configured
    XCTAssertEqual(configured, [Configuration(namespaceID: namespaceID, appID: 10, keyURL: keyURL)])
  }

  func testMissingPermissionsAreActionableBeforeRepositoryTokenCreation() async throws {
    let namespaceID = UUID()
    let broker = RecordingGitHubConnectionBroker(
      installations: [
        GitHubInstallationDescriptor(
          id: 20,
          accountLogin: "octo",
          accountType: "Organization",
          permissions: ["contents": "read"],
          isSuspended: false
        )
      ]
    )
    let controller = GitHubConnectionController(
      broker: broker,
      credentialCleanup: RecordingGitHubCredentialCleanup()
    )
    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )
    guard case .choosingInstallation(_, let installations) = controller.state(for: namespaceID)
    else { return XCTFail("Expected installations") }

    await controller.chooseInstallation(try XCTUnwrap(installations.first), namespaceID: namespaceID)

    guard case .failed(let message) = controller.state(for: namespaceID) else {
      return XCTFail("Expected permission failure")
    }
    XCTAssertTrue(message.contains("Issues: Read-only or Read and write"))
    XCTAssertTrue(message.contains("Contents: Read and write"))
    let repositoryRequestCount = await broker.repositoryRequestCount
    XCTAssertEqual(repositoryRequestCount, 0)
  }

  func testOneNamespaceSetupDoesNotChangeAnotherNamespaceState() async {
    let first = UUID()
    let second = UUID()
    let controller = GitHubConnectionController(
      broker: RecordingGitHubConnectionBroker(),
      credentialCleanup: RecordingGitHubCredentialCleanup()
    )

    await controller.beginConnection(
      namespaceID: first,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )

    guard case .choosingInstallation = controller.state(for: first) else {
      return XCTFail("Expected first namespace setup")
    }
    XCTAssertEqual(controller.state(for: second), .idle)
  }

  func testSaveFailurePurgesConfiguredCredentialBeforeRetry() async throws {
    let namespaceID = UUID()
    let broker = RecordingGitHubConnectionBroker()
    let cleanup = RecordingGitHubCredentialCleanup()
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)
    await controller.beginConnection(
      namespaceID: namespaceID,
      appIDText: "10",
      privateKeyFileURL: URL(fileURLWithPath: "/private/key.pem")
    )
    guard case .choosingInstallation(_, let installations) = controller.state(for: namespaceID)
    else { return XCTFail("Expected installations") }
    await controller.chooseInstallation(try XCTUnwrap(installations.first), namespaceID: namespaceID)
    guard case .choosingRepository(_, _, let repositories) = controller.state(for: namespaceID)
    else { return XCTFail("Expected repositories") }

    do {
      try await controller.connect(
        try XCTUnwrap(repositories.first),
        namespaceID: namespaceID,
        save: { _ in throw TestGitHubConnectionError.saveFailed }
      )
      XCTFail("Expected save failure")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Connection save failed.")
    }
    let purged = await cleanup.cleaned
    XCTAssertEqual(purged, [namespaceID])
  }

  func testCheckReportsRevokedInstallationAndDisconnectPersistsBeforePurge() async throws {
    let namespaceID = UUID()
    let operations = MainActorOperationRecorder()
    let broker = RecordingGitHubConnectionBroker(installations: [])
    let cleanup = RecordingGitHubCredentialCleanup(operations: operations)
    let controller = GitHubConnectionController(broker: broker, credentialCleanup: cleanup)
    let connection = try GitHubConnection(
      appID: 10,
      installationID: 20,
      accountLogin: "octo",
      repositoryID: 30,
      repositoryFullName: "octo/research",
      repositoryURL: URL(string: "https://github.com/octo/research")!
    )

    await controller.check(connection, namespaceID: namespaceID)
    guard case .failed(let message) = controller.state(for: namespaceID) else {
      return XCTFail("Expected revoked installation")
    }
    XCTAssertTrue(message.contains("no longer accessible"))

    _ = try await controller.disconnect(namespaceID: namespaceID) {
      operations.append("save-disconnected")
    }
    XCTAssertEqual(operations.values.suffix(3), ["stage", "save-disconnected", "purge"])
  }
}

private struct Configuration: Equatable, Sendable {
  let namespaceID: UUID
  let appID: Int64
  let keyURL: URL
}

private actor RecordingGitHubConnectionBroker: GitHubConnectionBrokering {
  private(set) var configured: [Configuration] = []
  private(set) var repositoryRequestCount = 0
  private let installations: [GitHubInstallationDescriptor]
  private let repositories: [GitHubRepositoryDescriptor]

  init(
    installations: [GitHubInstallationDescriptor] = [
      GitHubInstallationDescriptor(
        id: 20,
        accountLogin: "octo",
        accountType: "Organization",
        permissions: ["issues": "read", "contents": "write"],
        isSuspended: false
      )
    ],
    repositories: [GitHubRepositoryDescriptor] = [
      GitHubRepositoryDescriptor(
        id: 30,
        fullName: "octo/research",
        htmlURL: URL(string: "https://github.com/octo/research")!,
        isPrivate: true
      )
    ]
  ) {
    self.installations = installations
    self.repositories = repositories
  }

  func configureGitHubApp(
    appID: Int64,
    privateKeyFileURL: URL,
    namespaceID: UUID
  ) {
    configured.append(Configuration(namespaceID: namespaceID, appID: appID, keyURL: privateKeyFileURL))
  }

  func listGitHubInstallations(namespaceID: UUID) -> [GitHubInstallationDescriptor] {
    installations
  }

  func listGitHubRepositories(
    installationID: Int64,
    namespaceID: UUID
  ) -> [GitHubRepositoryDescriptor] {
    repositoryRequestCount += 1
    return repositories
  }

}

private actor RecordingGitHubCredentialCleanup: GitHubCredentialCleaning {
  private(set) var cleaned: [UUID] = []
  private let operations: MainActorOperationRecorder?

  init(operations: MainActorOperationRecorder? = nil) {
    self.operations = operations
  }

  func setupStarted(_ namespaceID: UUID) async {
    await operations?.append("stage")
  }

  func cleanup(_ namespaceID: UUID) async -> String? {
    cleaned.append(namespaceID)
    await operations?.append("purge")
    return nil
  }

  func connectionCommitted(_ namespaceID: UUID) {}
}

@MainActor
private final class MainActorOperationRecorder: @unchecked Sendable {
  private(set) var values: [String] = []
  func append(_ value: String) { values.append(value) }
}

private enum TestGitHubConnectionError: LocalizedError {
  case saveFailed
  var errorDescription: String? { "Connection save failed." }
}
