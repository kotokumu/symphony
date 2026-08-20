import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit
@testable import SymphonyCredentialBrokerProtocol

final class NamespaceGitHubAccessSessionTests: XCTestCase {
  func testAuthorizesOneExactRepositoryScopeIdempotentlyAndRejectsConflict() async throws {
    let root = try makeDirectory()
    let api = RecordingRepositoryAPI()
    let session = NamespaceGitHubAccessSession(api: api)
    let authorization = makeAuthorization(root: root)

    try await session.authorize(authorization, storedAppID: 10)
    try await session.authorize(authorization, storedAppID: 10)
    let hasScope = await session.hasAuthorizedScope
    XCTAssertTrue(hasScope)

    do {
      try await session.authorize(
        GitHubRepositoryAuthorization(
          appID: 10,
          installationID: 20,
          repositoryID: 31,
          repositoryFullName: "octo/other",
          repositoryURL: URL(string: "https://github.com/octo/other")!,
          workspacesRoot: root
        ),
        storedAppID: 10
      )
      XCTFail("Expected conflicting scope")
    } catch {}
  }

  func testRejectsAppMismatchTraversalAndUnsafeWorkspaceRootsBeforeMinting() async throws {
    let root = try makeDirectory()
    let api = RecordingRepositoryAPI()
    let cases = [
      GitHubRepositoryAuthorization(
        appID: 11,
        installationID: 20,
        repositoryID: 30,
        repositoryFullName: "octo/repo",
        repositoryURL: URL(string: "https://github.com/octo/repo")!,
        workspacesRoot: root
      ),
      GitHubRepositoryAuthorization(
        appID: 10,
        installationID: 20,
        repositoryID: 30,
        repositoryFullName: "../repo",
        repositoryURL: URL(string: "https://github.com/../repo")!,
        workspacesRoot: root
      ),
      GitHubRepositoryAuthorization(
        appID: 10,
        installationID: 20,
        repositoryID: 30,
        repositoryFullName: "octo/repo",
        repositoryURL: URL(string: "https://github.com/octo/repo")!,
        workspacesRoot: root.appendingPathComponent("missing")
      ),
    ]

    for authorization in cases {
      let session = NamespaceGitHubAccessSession(api: api)
      do {
        try await session.authorize(authorization, storedAppID: 10)
        XCTFail("Expected rejected scope")
      } catch {}
    }
    let rejectedMintCount = await api.mintCount
    XCTAssertEqual(rejectedMintCount, 0)
  }

  func testReusesFreshLeaseRefreshesAtMarginAndClearsOnLock() async throws {
    let root = try makeDirectory()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let api = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(301), now.addingTimeInterval(3_600)]
    )
    let session = NamespaceGitHubAccessSession(api: api, now: { now })
    try await session.authorize(makeAuthorization(root: root), storedAppID: 10)

    _ = try await session.performIssueRequest(.getIssue(issueNumber: 1), jwt: "jwt")
    _ = try await session.performIssueRequest(.getIssue(issueNumber: 2), jwt: "jwt")
    let reuseMintCount = await api.mintCount
    XCTAssertEqual(reuseMintCount, 1)
    let retained = await session.retainedTokenByteCount
    XCTAssertGreaterThan(retained, 0)

    let expiringAPI = RecordingRepositoryAPI(expirations: [now.addingTimeInterval(300)])
    let expiring = NamespaceGitHubAccessSession(api: expiringAPI, now: { now })
    try await expiring.authorize(makeAuthorization(root: root), storedAppID: 10)
    _ = try await expiring.performIssueRequest(.getIssue(issueNumber: 1), jwt: "jwt")
    let expiringMintCount = await expiringAPI.mintCount
    XCTAssertEqual(expiringMintCount, 1)

    await session.clear()
    let clearedBytes = await session.retainedTokenByteCount
    let clearedScope = await session.hasAuthorizedScope
    XCTAssertEqual(clearedBytes, 0)
    XCTAssertFalse(clearedScope)
  }

  func testRetriesOneReadAfter401ButNeverRedispatchesMutation() async throws {
    let root = try makeDirectory()
    let now = Date()
    let readAPI = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(3_600), now.addingTimeInterval(3_600)],
      issueResults: [
        .failure(.failure(
          GitHubCapabilityFailure(category: .authExpired, message: "expired", status: 401),
          invalidatesLease: true,
          retryGET: true
        )),
        .success(GitHubIssueCapabilityResponse(status: 200, body: Data("{}".utf8))),
      ]
    )
    let read = NamespaceGitHubAccessSession(api: readAPI, now: { now })
    try await read.authorize(makeAuthorization(root: root), storedAppID: 10)

    let readResponse = try await read.performIssueRequest(.getIssue(issueNumber: 1), jwt: "jwt")
    XCTAssertEqual(readResponse.status, 200)
    let readMintCount = await readAPI.mintCount
    let readIssueCount = await readAPI.issueCount
    XCTAssertEqual(readMintCount, 2)
    XCTAssertEqual(readIssueCount, 2)

    let mutationAPI = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(3_600)],
      issueResults: [.failure(.failure(
        GitHubCapabilityFailure(category: .authExpired, message: "expired", status: 401),
        invalidatesLease: true,
        retryGET: true
      ))]
    )
    let mutation = NamespaceGitHubAccessSession(api: mutationAPI, now: { now })
    try await mutation.authorize(makeAuthorization(root: root), storedAppID: 10)
    do {
      _ = try await mutation.performIssueRequest(
        .createComment(issueNumber: 1, body: "hello"),
        jwt: "jwt"
      )
      XCTFail("Expected ambiguous mutation failure")
    } catch let error as GitHubRepositoryAPIError {
      XCTAssertEqual(error.failure.category, .ambiguousMutationAuthenticationFailure)
      XCTAssertTrue(error.failure.effectMayHaveOccurred)
    }
    let mutationIssueCount = await mutationAPI.issueCount
    XCTAssertEqual(mutationIssueCount, 1)
  }

  private func makeAuthorization(root: URL) -> GitHubRepositoryAuthorization {
    GitHubRepositoryAuthorization(
      appID: 10,
      installationID: 20,
      repositoryID: 30,
      repositoryFullName: "octo/repo",
      repositoryURL: URL(string: "https://github.com/octo/repo.git")!,
      workspacesRoot: root
    )
  }

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-access-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}

private actor RecordingRepositoryAPI: GitHubRepositoryAPIRequesting {
  private(set) var mintCount = 0
  private(set) var issueCount = 0
  private var expirations: [Date]
  private var issueResults: [Result<GitHubIssueCapabilityResponse, GitHubRepositoryAPIError>]

  init(
    expirations: [Date] = [Date().addingTimeInterval(3_600)],
    issueResults: [Result<GitHubIssueCapabilityResponse, GitHubRepositoryAPIError>] = []
  ) {
    self.expirations = expirations
    self.issueResults = issueResults
  }

  func mintInstallationToken(
    scope: AuthorizedGitHubRepositoryScope,
    jwt: String
  ) throws -> InstallationTokenLease {
    mintCount += 1
    let expiration = expirations.isEmpty ? Date().addingTimeInterval(3_600) : expirations.removeFirst()
    return InstallationTokenLease(
      token: SecureSecretBuffer(copying: Data("token-\(mintCount)".utf8)),
      expiresAt: expiration
    )
  }

  func performIssueRequest(
    _ request: GitHubIssueCapabilityRequest,
    scope: AuthorizedGitHubRepositoryScope,
    token: SecureSecretBuffer
  ) throws -> GitHubIssueCapabilityResponse {
    issueCount += 1
    if !issueResults.isEmpty { return try issueResults.removeFirst().get() }
    return GitHubIssueCapabilityResponse(status: 200, body: Data("{}".utf8))
  }
}
