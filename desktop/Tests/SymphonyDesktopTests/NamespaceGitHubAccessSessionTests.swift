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
    } catch let error as GitHubRepositoryAccessError {
      XCTAssertEqual(error.failure.category, .unauthorizedScope)
    } catch {
      XCTFail("Unexpected conflicting-scope error: \(error)")
    }
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

    for (index, authorization) in cases.enumerated() {
      let session = NamespaceGitHubAccessSession(api: api)
      do {
        try await session.authorize(authorization, storedAppID: 10)
        XCTFail("Expected rejected scope")
      } catch let error as GitHubRepositoryAccessError {
        XCTAssertEqual(error.failure.category, .unauthorizedScope)
        if index == 2 {
          switch error {
          case .invalidWorkspaceRoot: break
          default: XCTFail("Expected invalid workspace root, got \(error)")
          }
        } else {
          switch error {
          case .unauthorizedScope: break
          default: XCTFail("Expected unauthorized scope, got \(error)")
          }
        }
      } catch {
        XCTFail("Unexpected scope-validation error: \(error)")
      }
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
        GitHubCapabilityFailure(
          category: .networkUnavailable,
          message: "lost",
          effectMayHaveOccurred: true
        ),
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

  func testSecondRead401StopsRetryAndPermissionFailureForcesNextRequestToRemint() async throws {
    let root = try makeDirectory()
    let now = Date()
    let expired = GitHubRepositoryAPIError.failure(
      GitHubCapabilityFailure(category: .authExpired, message: "expired", status: 401),
      invalidatesLease: true,
      retryGET: true
    )
    let repeatedAPI = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(3_600), now.addingTimeInterval(3_600)],
      issueResults: [.failure(expired), .failure(expired)]
    )
    let repeated = NamespaceGitHubAccessSession(api: repeatedAPI, now: { now })
    try await repeated.authorize(makeAuthorization(root: root), storedAppID: 10)
    do {
      _ = try await repeated.performIssueRequest(.getIssue(issueNumber: 1), jwt: "jwt")
      XCTFail("Expected refreshed App authentication rejection")
    } catch let error as GitHubRepositoryAPIError {
      XCTAssertEqual(error.failure.category, .appCredentialRejected)
    }
    let repeatedIssueCount = await repeatedAPI.issueCount
    let repeatedMintCount = await repeatedAPI.mintCount
    XCTAssertEqual(repeatedIssueCount, 2)
    XCTAssertEqual(repeatedMintCount, 2)

    let deniedAPI = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(3_600), now.addingTimeInterval(3_600)],
      issueResults: [.failure(.failure(
        GitHubCapabilityFailure(category: .permissionDenied, message: "denied", status: 403),
        invalidatesLease: true,
        retryGET: false
      ))]
    )
    let denied = NamespaceGitHubAccessSession(api: deniedAPI, now: { now })
    try await denied.authorize(makeAuthorization(root: root), storedAppID: 10)
    do {
      _ = try await denied.performIssueRequest(.getIssue(issueNumber: 1), jwt: "jwt")
      XCTFail("Expected permission denial")
    } catch let error as GitHubRepositoryAPIError {
      XCTAssertEqual(error.failure.category, .permissionDenied)
    }
    _ = try await denied.performIssueRequest(.getIssue(issueNumber: 2), jwt: "jwt")
    let deniedMintCount = await deniedAPI.mintCount
    XCTAssertEqual(deniedMintCount, 2)
  }

  func testGitCredentialEraseFailureClearsLeaseBeforeManualRetry() async throws {
    let root = try makeDirectory()
    let now = Date()
    let api = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(3_600), now.addingTimeInterval(3_600)]
    )
    let git = RecordingGitRunner(results: [
      .failure(GitCommandRunnerError.authenticationRejected),
      .success(GitRepositoryCapabilityResult(exitStatus: 0, output: "", wasTruncated: false)),
    ])
    let session = NamespaceGitHubAccessSession(api: api, git: git, now: { now })
    try await session.authorize(makeAuthorization(root: root), storedAppID: 10)
    do {
      _ = try await session.performGitOperation(.clone(targetName: "first"), jwt: "jwt")
      XCTFail("Expected helper erase rejection")
    } catch let error as GitHubRepositoryAPIError {
      XCTAssertEqual(error.failure.category, .gitAuthenticationRejected)
    }
    _ = try await session.performGitOperation(.clone(targetName: "second"), jwt: "jwt")
    let mintCount = await api.mintCount
    XCTAssertEqual(mintCount, 2)
  }

  func testGitStopFailureKeepsAdmissionClosedUntilCleanupRetrySucceeds() async throws {
    let root = try makeDirectory()
    let git = FailOnceStopGitRunner()
    let session = NamespaceGitHubAccessSession(api: RecordingRepositoryAPI(), git: git)
    try await session.authorize(makeAuthorization(root: root), storedAppID: 10)

    do {
      try await session.quiesceAndClear()
      XCTFail("Expected retained Git cleanup failure")
    } catch let error as GitCommandRunnerError {
      XCTAssertEqual(error.failure.category, .cleanupRequired)
    }
    do {
      _ = try await session.performGitOperation(.clone(targetName: "blocked"), jwt: "jwt")
      XCTFail("Expected admission to remain closed")
    } catch let error as GitHubRepositoryAccessError {
      XCTAssertEqual(error.failure.category, .locked)
    }
    do {
      try await session.authorize(makeAuthorization(root: root), storedAppID: 10)
      XCTFail("Expected replacement authorization to remain closed")
    } catch let error as GitHubRepositoryAccessError {
      XCTAssertEqual(error.failure.category, .locked)
    }

    try await session.quiesceAndClear()
    let stopCount = await git.stopCount
    let hasScope = await session.hasAuthorizedScope
    XCTAssertEqual(stopCount, 2)
    XCTAssertFalse(hasScope)
  }

  func testRedactsCredentialCanariesFromEveryTypedIssueTextField() async throws {
    let root = try makeDirectory()
    let now = Date()
    let api = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(3_600)],
      issueResults: [.success(.issue(GitHubIssueRecord(
        number: 1,
        title: "token-1",
        body: "Bearer token-1",
        authorLogin: "token-1",
        labels: ["prefix-token-1"],
        assigneeLogins: [Data("token-1".utf8).base64EncodedString()]
      )))]
    )
    let session = NamespaceGitHubAccessSession(api: api, now: { now })
    try await session.authorize(makeAuthorization(root: root), storedAppID: 10)

    let response = try await session.performIssueRequest(.getIssue(issueNumber: 1), jwt: "jwt")
    let encoded = try JSONEncoder().encode(response)
    let text = String(decoding: encoded, as: UTF8.self)
    XCTAssertFalse(text.contains("token-1"))
    XCTAssertFalse(text.contains(Data("token-1".utf8).base64EncodedString()))
    XCTAssertTrue(text.contains("REDACTED"))
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
        GitHubCapabilityFailure(
          category: .authExpired,
          message: "expired",
          status: 401,
          effectMayHaveOccurred: true
        ),
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

  func testSafelyRefreshesMutationWhenAuthenticationFailsBeforeDispatch() async throws {
    let root = try makeDirectory()
    let now = Date()
    let api = RecordingRepositoryAPI(
      expirations: [now.addingTimeInterval(3_600), now.addingTimeInterval(3_600)],
      issueResults: [
        .failure(.failure(
          GitHubCapabilityFailure(category: .authExpired, message: "preflight expired", status: 401),
          invalidatesLease: true,
          retryGET: true
        )),
        .success(.comment(GitHubIssueCommentRecord(id: 70, body: "created"))),
      ]
    )
    let session = NamespaceGitHubAccessSession(api: api, now: { now })
    try await session.authorize(makeAuthorization(root: root), storedAppID: 10)

    let response = try await session.performIssueRequest(
      .createComment(issueNumber: 7, body: "created"),
      jwt: "jwt"
    )

    XCTAssertEqual(response, .comment(GitHubIssueCommentRecord(id: 70, body: "created")))
    let issueCount = await api.issueCount
    let mintCount = await api.mintCount
    XCTAssertEqual(issueCount, 2)
    XCTAssertEqual(mintCount, 2)
  }

  func testRealAPIPreflightRefreshesWithoutRedispatchingTheMutation() async throws {
    let root = try makeDirectory()
    let transport = AccessSequenceTransport(responses: [
      .json(status: 201, body: #"{"token":"first","expires_at":"2030-01-01T00:00:00Z"}"#),
      .json(status: 401, body: "{}"),
      .json(status: 201, body: #"{"token":"second","expires_at":"2030-01-01T00:00:00Z"}"#),
      .json(status: 200, body: #"{"number":7}"#),
      .json(status: 201, body: #"{"id":70,"body":"created"}"#),
    ])
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport
    )
    let session = NamespaceGitHubAccessSession(api: client)
    try await session.authorize(makeAuthorization(root: root), storedAppID: 10)

    let result = try await session.performIssueRequest(
      .createComment(issueNumber: 7, body: "created"),
      jwt: "jwt"
    )

    XCTAssertEqual(result, .comment(GitHubIssueCommentRecord(id: 70, body: "created")))
    let requests = await transport.requests
    XCTAssertEqual(
      requests.map { [$0.httpMethod ?? "", $0.url?.path ?? ""] },
      [
        ["POST", "/app/installations/20/access_tokens"],
        ["GET", "/repos/octo/repo/issues/7"],
        ["POST", "/app/installations/20/access_tokens"],
        ["GET", "/repos/octo/repo/issues/7"],
        ["POST", "/repos/octo/repo/issues/7/comments"],
      ]
    )
    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/comments") == true }.count, 1)
  }

  func testSecondAttemptDispatchedFailuresRemainAmbiguous() async throws {
    for (category, expected) in [
      (
        GitHubCapabilityFailure.Category.authExpired,
        GitHubCapabilityFailure.Category.ambiguousMutationAuthenticationFailure
      ),
      (.networkUnavailable, .ambiguousMutationFailure),
    ] {
      let root = try makeDirectory()
      let api = RecordingRepositoryAPI(
        expirations: [Date().addingTimeInterval(3_600), Date().addingTimeInterval(3_600)],
        issueResults: [
          .failure(.failure(
            GitHubCapabilityFailure(category: .authExpired, message: "preflight", status: 401),
            invalidatesLease: true,
            retryGET: true
          )),
          .failure(.failure(
            GitHubCapabilityFailure(
              category: category,
              message: "dispatched",
              status: category == .authExpired ? 401 : nil,
              effectMayHaveOccurred: true
            ),
            invalidatesLease: category == .authExpired,
            retryGET: category == .authExpired
          )),
        ]
      )
      let session = NamespaceGitHubAccessSession(api: api)
      try await session.authorize(makeAuthorization(root: root), storedAppID: 10)

      do {
        _ = try await session.performIssueRequest(
          .createComment(issueNumber: 7, body: "created"),
          jwt: "jwt"
        )
        XCTFail("Expected ambiguous refreshed mutation failure")
      } catch let error as GitHubRepositoryAPIError {
        XCTAssertEqual(error.failure.category, expected)
        XCTAssertTrue(error.failure.effectMayHaveOccurred)
      }
      let issueCount = await api.issueCount
      XCTAssertEqual(issueCount, 2)
    }
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

private actor AccessSequenceTransport: GitHubHTTPTransporting {
  struct Response: Sendable {
    let status: Int
    let data: Data

    static func json(status: Int, body: String) -> Self {
      Self(status: status, data: Data(body.utf8))
    }
  }

  private var responses: [Response]
  private(set) var requests: [URLRequest] = []

  init(responses: [Response]) { self.responses = responses }

  func data(
    for request: URLRequest,
    maximumBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let response = responses.removeFirst()
    return (
      response.data,
      HTTPURLResponse(
        url: request.url!,
        statusCode: response.status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
    )
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

private actor RecordingGitRunner: ScopedGitRunning {
  private var results: [Result<GitRepositoryCapabilityResult, GitCommandRunnerError>]

  init(results: [Result<GitRepositoryCapabilityResult, GitCommandRunnerError>]) {
    self.results = results
  }

  func run(
    _ request: GitRepositoryCapabilityRequest,
    in scope: AuthorizedGitHubRepositoryScope,
    acquireCredential: @escaping @Sendable () async throws -> OperationCredential
  ) async throws -> GitRepositoryCapabilityResult {
    let credential = try await acquireCredential()
    defer { credential.clear() }
    return try results.removeFirst().get()
  }

  func stopRetainedOperation() async throws {}
}

private actor FailOnceStopGitRunner: ScopedGitRunning {
  private(set) var stopCount = 0

  func run(
    _ request: GitRepositoryCapabilityRequest,
    in scope: AuthorizedGitHubRepositoryScope,
    acquireCredential: @escaping @Sendable () async throws -> OperationCredential
  ) async throws -> GitRepositoryCapabilityResult {
    throw GitCommandRunnerError.cleanupRequired
  }

  func stopRetainedOperation() throws {
    stopCount += 1
    if stopCount == 1 { throw GitCommandRunnerError.cleanupRequired }
  }
}
