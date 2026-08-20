import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit
@testable import SymphonyCredentialBrokerProtocol

final class GitCredentialHelperTests: XCTestCase {
  func testReturnsCredentialOnlyForTheAuthorizedGitHubRepository() async throws {
    let fixture = try makeServer()
    let task = Task.detached { fixture.server.serve() }
    defer { fixture.server.stop() }
    let environment = helperEnvironment(fixture.server)

    let matching = BrokerGitCredentialHelper.exchange(
      action: "get",
      input: Data("protocol=https\nhost=GitHub.com\npath=OCTO/REPO.git\n\n".utf8),
      environment: environment
    )
    XCTAssertEqual(matching.status, 0)
    XCTAssertEqual(
      String(decoding: matching.output, as: UTF8.self),
      "username=x-access-token\npassword=canary-token\n\n"
    )

    for input in [
      "protocol=http\nhost=github.com\npath=octo/repo\n\n",
      "protocol=https\nhost=github.com:443\npath=octo/repo\n\n",
      "protocol=https\nhost=github.com\npath=other/repo\n\n",
      "protocol=https\nhost=github.com\npath=octo/repo%2Fother\n\n",
    ] {
      let rejected = BrokerGitCredentialHelper.exchange(
        action: "get",
        input: Data(input.utf8),
        environment: environment
      )
      XCTAssertNotEqual(rejected.status, 0)
      XCTAssertTrue(rejected.output.isEmpty)
    }
    fixture.server.stop()
    _ = await task.value
  }

  func testStoreDoesNothingAndEraseInvalidatesTheOperation() async throws {
    let fixture = try makeServer()
    let task = Task.detached { fixture.server.serve() }
    let environment = helperEnvironment(fixture.server)

    let store = BrokerGitCredentialHelper.exchange(
      action: "store",
      input: Data("password=must-not-be-stored\n\n".utf8),
      environment: environment
    )
    XCTAssertEqual(store.status, 0)
    XCTAssertTrue(store.output.isEmpty)
    XCTAssertFalse(fixture.server.authenticationWasRejected)

    let erase = BrokerGitCredentialHelper.exchange(
      action: "erase",
      input: Data("protocol=https\n\n".utf8),
      environment: environment
    )
    XCTAssertEqual(erase.status, 0)
    XCTAssertTrue(erase.output.isEmpty)
    XCTAssertTrue(fixture.server.authenticationWasRejected)
    fixture.server.stop()
    _ = await task.value
  }

  func testDirectInvocationAndOversizedInputFailWithoutCredentialOutput() {
    let missing = BrokerGitCredentialHelper.exchange(
      action: "get",
      input: Data("protocol=https\n".utf8),
      environment: [:]
    )
    XCTAssertNotEqual(missing.status, 0)
    XCTAssertTrue(missing.output.isEmpty)

    let oversized = BrokerGitCredentialHelper.exchange(
      action: "get",
      input: Data(repeating: 0x61, count: CredentialBrokerProtocolLimits.maximumGitCredentialInputBytes + 1),
      environment: ["SYMPHONY_GIT_HELPER_FD": "3"]
    )
    XCTAssertNotEqual(oversized.status, 0)
    XCTAssertTrue(oversized.output.isEmpty)
  }

  private func makeServer() throws -> (
    server: PrivateGitCredentialServer,
    credential: OperationCredential,
    root: URL
  ) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let scope = try AuthorizedGitHubRepositoryScope(
      GitHubRepositoryAuthorization(
        appID: 10,
        installationID: 20,
        repositoryID: 30,
        repositoryFullName: "octo/repo",
        repositoryURL: URL(string: "https://github.com/octo/repo")!,
        workspacesRoot: root
      ),
      storedAppID: 10
    )
    let source = SecureSecretBuffer(copying: Data("canary-token".utf8))
    let credential = OperationCredential(copying: source)
    source.clear()
    return (try PrivateGitCredentialServer(scope: scope, credential: credential), credential, root)
  }

  private func helperEnvironment(_ server: PrivateGitCredentialServer) -> [String: String] {
    server.helperEnvironment
  }
}
