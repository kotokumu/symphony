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
    let clock = MutableDateClock(now)
    let api = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(601), now.addingTimeInterval(3_600)]
    )
    let session = NamespaceGitHubAccessSession(api: api, now: { clock.value })
    try await session.authorize(makeAuthorization(root: root), storedAppID: 10)

    _ = try await session.performIssueRequest(.getIssue(issueNumber: 1), jwt: "jwt")
    _ = try await session.performIssueRequest(.getIssue(issueNumber: 2), jwt: "jwt")
    let reuseMintCount = await api.mintCount
    XCTAssertEqual(reuseMintCount, 1)
    let retained = await session.retainedTokenByteCount
    XCTAssertGreaterThan(retained, 0)

    clock.advance(by: 301)
    _ = try await session.performIssueRequest(.getIssue(issueNumber: 3), jwt: "jwt")
    let refreshedMintCount = await api.mintCount
    XCTAssertEqual(refreshedMintCount, 2)
    let leases = await api.mintedLeases
    XCTAssertEqual(leases.count, 2)
    XCTAssertEqual(leases[0].token.retainedByteCount, 0)
    XCTAssertGreaterThan(leases[1].token.retainedByteCount, 0)

    try await session.quiesceAndClear()
    let clearedBytes = await session.retainedTokenByteCount
    let clearedScope = await session.hasAuthorizedScope
    XCTAssertEqual(clearedBytes, 0)
    XCTAssertFalse(clearedScope)
  }

  func testQuiesceCancelsInFlightAPIAndClearsAdmissionBeforeReturning() async throws {
    let root = try makeDirectory()
    let api = CancellableRepositoryAPI()
    let session = NamespaceGitHubAccessSession(api: api)
    try await session.authorize(makeAuthorization(root: root), storedAppID: 10)
    let operation = Task {
      try await session.performIssueRequest(.getIssue(issueNumber: 1), jwt: "jwt")
    }
    await api.waitUntilIssueStarted()
    try await session.quiesceAndClear()
    do {
      _ = try await operation.value
      XCTFail("Expected in-flight API cancellation")
    } catch is CancellationError {}
    let hasScope = await session.hasAuthorizedScope
    let retainedBytes = await session.retainedTokenByteCount
    XCTAssertFalse(hasScope)
    XCTAssertEqual(retainedBytes, 0)
  }

  func testNetworkLossAfterMutationDispatchIsReportedAsAmbiguous() async throws {
    let root = try makeDirectory()
    let now = Date()
    let api = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(3_600)],
      issueResults: [.failure(.failure(
        GitHubCapabilityFailure(category: .networkUnavailable, message: "lost"),
        invalidatesLease: false,
        retryGET: false
      ))]
    )
    let session = NamespaceGitHubAccessSession(api: api, now: { now })
    try await session.authorize(makeAuthorization(root: root), storedAppID: 10)
    do {
      _ = try await session.performIssueRequest(
        .createComment(issueNumber: 1, body: "hello"),
        jwt: "jwt"
      )
      XCTFail("Expected ambiguous mutation")
    } catch let error as GitHubRepositoryAPIError {
      XCTAssertEqual(error.failure.category, .ambiguousMutationFailure)
      XCTAssertTrue(error.failure.effectMayHaveOccurred)
    }
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
        .success(.issue(GitHubIssueRecord(number: 1))),
      ]
    )
    let read = NamespaceGitHubAccessSession(api: readAPI, now: { now })
    try await read.authorize(makeAuthorization(root: root), storedAppID: 10)

    let readResponse = try await read.performIssueRequest(.getIssue(issueNumber: 1), jwt: "jwt")
    XCTAssertEqual(readResponse, .issue(GitHubIssueRecord(number: 1)))
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
  private(set) var mintedLeases: [InstallationTokenLease] = []
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
    let lease = InstallationTokenLease(
      token: SecureSecretBuffer(copying: Data("token-\(mintCount)".utf8)),
      expiresAt: expiration
    )
    mintedLeases.append(lease)
    return lease
  }

  func performIssueRequest(
    _ request: GitHubIssueCapabilityRequest,
    scope: AuthorizedGitHubRepositoryScope,
    token: SecureSecretBuffer
  ) throws -> GitHubIssueCapabilityResponse {
    issueCount += 1
    if !issueResults.isEmpty { return try issueResults.removeFirst().get() }
    return .issue(GitHubIssueRecord(number: 1))
  }
}

private final class MutableDateClock: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Date
  init(_ value: Date) { stored = value }
  var value: Date { lock.withLock { stored } }
  func advance(by seconds: TimeInterval) { lock.withLock { stored.addTimeInterval(seconds) } }
}

private actor CancellableRepositoryAPI: GitHubRepositoryAPIRequesting {
  private var issueStarted = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func mintInstallationToken(
    scope: AuthorizedGitHubRepositoryScope,
    jwt: String
  ) -> InstallationTokenLease {
    InstallationTokenLease(
      token: SecureSecretBuffer(copying: Data("token".utf8)),
      expiresAt: Date().addingTimeInterval(3_600)
    )
  }

  func performIssueRequest(
    _ request: GitHubIssueCapabilityRequest,
    scope: AuthorizedGitHubRepositoryScope,
    token: SecureSecretBuffer
  ) async throws -> GitHubIssueCapabilityResponse {
    issueStarted = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
    try await Task.sleep(for: .seconds(60))
    return .issue(GitHubIssueRecord(number: 1))
  }

  func waitUntilIssueStarted() async {
    if issueStarted { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}
