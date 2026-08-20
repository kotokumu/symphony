import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit
@testable import SymphonyCredentialBrokerProtocol

final class GitHubRepositoryAPIClientTests: XCTestCase {
  func testMintsARepositoryAndPermissionScopedTokenThenBuildsTypedIssueRequests() async throws {
    let transport = RepositoryTransport(responses: [
      .json(
        status: 201,
        body: #"{"token":"short-lived-secret","expires_at":"2030-01-01T00:00:00Z"}"#
      ),
      .json(status: 200, body: #"[{"number":7}]"#),
    ])
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport
    )
    let fixture = try makeScope()

    let lease = try await client.mintInstallationToken(scope: fixture.scope, jwt: "signed-jwt")
    let response = try await client.performIssueRequest(
      .listIssues(
        try GitHubIssueListQuery(
          state: .all,
          labels: ["desktop"],
          assignee: "octocat",
          since: "2026-08-20T00:00:00Z",
          pagination: try GitHubPage(perPage: 100, page: 2)
        )
      ),
      scope: fixture.scope,
      token: lease.token
    )

    XCTAssertEqual(response.status, 200)
    let requests = await transport.requests
    XCTAssertEqual(requests[0].url?.path, "/app/installations/20/access_tokens")
    let body = try XCTUnwrap(requests[0].httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["repository_ids"] as? [Int], [30])
    XCTAssertEqual(
      json["permissions"] as? [String: String],
      ["contents": "write", "issues": "write", "metadata": "read"]
    )
    XCTAssertEqual(requests[1].url?.path, "/repos/octo/repo/issues")
    let queryItems = try XCTUnwrap(
      URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
    )
    XCTAssertEqual(
      queryItems.map { [$0.name, $0.value ?? ""] },
      [
        ["state", "all"], ["per_page", "100"], ["page", "2"],
        ["labels", "desktop"], ["assignee", "octocat"],
        ["since", "2026-08-20T00:00:00Z"],
      ]
    )
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer short-lived-secret")
    lease.clear()
  }

  func testMapsEveryStatusClassWithoutReturningFailureBodies() async throws {
    let fixture = try makeScope()
    let cases: [(Int, [String: String], GitHubCapabilityFailure.Category)] = [
      (302, ["Location": "https://evil.test"], .redirectRejected),
      (401, [:], .authExpired),
      (403, [:], .permissionDenied),
      (403, ["X-RateLimit-Remaining": "0"], .rateLimited),
      (404, [:], .resourceNotFound),
      (422, [:], .invalidRequest),
      (429, ["Retry-After": "60"], .rateLimited),
      (500, [:], .serviceUnavailable),
    ]
    for (status, headers, category) in cases {
      let transport = RepositoryTransport(responses: [
        .init(status: status, headers: headers, data: Data("secret-echo".utf8))
      ])
      let client = GitHubAppAPIClient(
        baseURL: URL(string: "https://api.github.test")!,
        transport: transport
      )
      let token = SecureSecretBuffer(copying: Data("token".utf8))
      defer { token.clear() }
      do {
        _ = try await client.performIssueRequest(
          .getIssue(issueNumber: 7),
          scope: fixture.scope,
          token: token
        )
        XCTFail("Expected HTTP \(status)")
      } catch let error as GitHubRepositoryAPIError {
        XCTAssertEqual(error.failure.category, category)
        XCTAssertFalse(error.failure.message.contains("secret-echo"))
      }
    }
  }

  private func makeScope() throws -> (root: URL, scope: AuthorizedGitHubRepositoryScope) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-api-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let authorization = GitHubRepositoryAuthorization(
      appID: 10,
      installationID: 20,
      repositoryID: 30,
      repositoryFullName: "octo/repo",
      repositoryURL: URL(string: "https://github.com/octo/repo")!,
      workspacesRoot: root
    )
    return (root, try AuthorizedGitHubRepositoryScope(authorization, storedAppID: 10))
  }
}

private actor RepositoryTransport: GitHubHTTPTransporting {
  struct Response: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data

    static func json(status: Int, body: String) -> Self {
      Self(status: status, headers: ["Content-Type": "application/json"], data: Data(body.utf8))
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
    guard response.data.count <= maximumBytes else { throw GitHubAppAPIError.responseTooLarge }
    return (
      response.data,
      HTTPURLResponse(
        url: request.url!,
        statusCode: response.status,
        httpVersion: "HTTP/1.1",
        headerFields: response.headers
      )!
    )
  }
}
