import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit
@testable import SymphonyCredentialBrokerProtocol

final class GitHubAppAPIClientTests: XCTestCase {
  func testListsInstallationsAndRepositoriesWithoutReturningInstallationToken() async throws {
    let transport = StubGitHubTransport(
      responses: [
        .json(
          status: 200,
          body: """
            [{"id":20,"account":{"login":"octo","type":"Organization"},"permissions":{"issues":"read","contents":"write"},"suspended_at":null}]
            """
        ),
        .json(status: 201, body: "{\"token\":\"short-lived-secret\"}"),
        .json(
          status: 200,
          body: """
            {"total_count":1,"repositories":[{"id":30,"full_name":"octo/research","html_url":"https://github.com/octo/research","private":true}]}
            """
        ),
      ]
    )
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport
    )

    let installations = try await client.listInstallations(jwt: "signed-jwt")
    let repositories = try await client.listRepositories(
      installationID: 20,
      jwt: "signed-jwt"
    )

    XCTAssertEqual(installations.first?.accountLogin, "octo")
    XCTAssertEqual(installations.first?.permissions["contents"], "write")
    XCTAssertEqual(repositories.first?.fullName, "octo/research")
    let requests = await transport.requests
    XCTAssertEqual(requests.map(\.url?.path), ["/app/installations", "/app/installations/20/access_tokens", "/installation/repositories"])
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer signed-jwt")
    XCTAssertEqual(requests[1].httpMethod, "POST")
    XCTAssertEqual(
      requests[1].httpBody,
      Data("{\"permissions\":{\"metadata\":\"read\"}}".utf8)
    )
    XCTAssertEqual(
      requests[2].value(forHTTPHeaderField: "Authorization"),
      "Bearer short-lived-secret"
    )
  }

  func testMapsRejectedCredentialsRevocationAndPermissionFailuresToActions() async {
    let scenarios: [(Int, String, String)] = [
      (401, "{}", "Verify the GitHub App settings"),
      (403, "{\"message\":\"Resource not accessible by integration\"}", "required permission"),
      (404, "{}", "no longer accessible"),
    ]

    for (status, body, expected) in scenarios {
      let transport = StubGitHubTransport(
        responses: [
          .json(status: 201, body: "{\"token\":\"token\"}"),
          .json(status: status, body: body),
        ]
      )
      let client = GitHubAppAPIClient(
        baseURL: URL(string: "https://api.github.test")!,
        transport: transport
      )
      do {
        _ = try await client.listRepositories(installationID: 20, jwt: "jwt")
        XCTFail("Expected GitHub API failure")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
      }
    }
  }

  func testTransportUsesNoSharedCacheCookiesOrCredentialStorage() {
    let configuration = URLSessionGitHubHTTPTransport.makeEphemeralConfiguration()

    XCTAssertNil(configuration.urlCache)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertNil(configuration.urlCredentialStorage)
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
  }

  func testRejectsPlaintextBaseURLBeforeSendingJWT() async {
    let transport = StubGitHubTransport(responses: [])
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "http://api.github.test")!,
      transport: transport
    )

    do {
      _ = try await client.listInstallations(jwt: "must-not-be-sent")
      XCTFail("Expected HTTPS enforcement")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testPaginatesInstallationsAndStopsOnShortPage() async throws {
    let firstPage = installationPage(count: 100, startingAt: 1)
    let transport = StubGitHubTransport(
      responses: [
        .json(status: 200, body: firstPage),
        .json(status: 200, body: installationPage(count: 1, startingAt: 101)),
      ]
    )
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport
    )

    let values = try await client.listInstallations(jwt: "jwt")

    XCTAssertEqual(values.count, 101)
    let requests = await transport.requests
    XCTAssertEqual(requests[0].url?.query, "per_page=100&page=1")
    XCTAssertEqual(requests[1].url?.query, "per_page=100&page=2")
  }

  func testRejectsMalformedAndOversizedResponses() async {
    let cases: [(Data, String)] = [
      (Data("not-json".utf8), "unreadable response"),
      (Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1), "more connection data"),
    ]
    for (data, expected) in cases {
      let transport = StubGitHubTransport(responses: [.init(status: 200, data: data)])
      let client = GitHubAppAPIClient(
        baseURL: URL(string: "https://api.github.test")!,
        transport: transport
      )
      do {
        _ = try await client.listInstallations(jwt: "jwt")
        XCTFail("Expected bounded response failure")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
      }
    }
  }

  func testRejectsInvalidInstallationBeforeSendingRequest() async {
    let transport = StubGitHubTransport(responses: [])
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport
    )

    do {
      _ = try await client.listRepositories(installationID: 0, jwt: "jwt")
      XCTFail("Expected invalid installation")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("no longer accessible"))
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testMapsTransportFailureWithoutLeakingJWT() async {
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: FailingGitHubTransport()
    )

    do {
      _ = try await client.listInstallations(jwt: "secret-jwt")
      XCTFail("Expected transport failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("could not be reached"))
      XCTAssertFalse(error.localizedDescription.contains("secret-jwt"))
    }
  }

  func testIssueListFiltersPullRequestsAndGetRejectsPullRequests() async throws {
    let scope = try makeRepositoryScope()
    let token = SecureSecretBuffer(copying: Data("installation-token".utf8))
    defer { token.clear() }
    let pullRequest = """
      {"number":7,"title":"PR","state":"open","pull_request":{"url":"https://api.github.test/pulls/7"}}
      """
    let issue = """
      {"number":8,"title":"Issue","state":"open"}
      """
    let transport = StubGitHubTransport(
      responses: [
        .json(status: 200, body: "[\(pullRequest),\(issue)]"),
        .json(status: 200, body: pullRequest),
      ]
    )
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport
    )

    let listed = try await client.performIssueRequest(
      .listIssues(try GitHubIssueListQuery()),
      scope: scope,
      token: token
    )
    XCTAssertEqual(listed, .issueList([GitHubIssueRecord(number: 8, title: "Issue", state: .open)]))

    do {
      _ = try await client.performIssueRequest(.getIssue(issueNumber: 7), scope: scope, token: token)
      XCTFail("Expected pull request rejection")
    } catch let error as GitHubRepositoryAPIError {
      XCTAssertEqual(error.failure.category, .invalidRequest)
    }
  }

  func testIssueMutationsValidateTargetTypeBeforeSendingMutation() async throws {
    let operations: [GitHubIssueCapabilityRequest] = [
      .listComments(issueNumber: 7, page: .default),
      .createComment(issueNumber: 7, body: "comment"),
      .setIssueState(issueNumber: 7, state: .closed),
    ]
    for operation in operations {
      let scope = try makeRepositoryScope()
      let token = SecureSecretBuffer(copying: Data("installation-token".utf8))
      defer { token.clear() }
      let transport = StubGitHubTransport(
        responses: [
          .json(
            status: 200,
            body: "{\"number\":7,\"state\":\"open\",\"pull_request\":{\"url\":\"https://api.github.test/pulls/7\"}}"
          )
        ]
      )
      let client = GitHubAppAPIClient(
        baseURL: URL(string: "https://api.github.test")!,
        transport: transport
      )

      do {
        _ = try await client.performIssueRequest(operation, scope: scope, token: token)
        XCTFail("Expected pull request rejection")
      } catch let error as GitHubRepositoryAPIError {
        XCTAssertEqual(error.failure.category, .invalidRequest)
      }
      let requests = await transport.requests
      XCTAssertEqual(requests.count, 1)
      XCTAssertEqual(requests[0].httpMethod, "GET")
      XCTAssertEqual(requests[0].url?.path, "/repos/octo/repo/issues/7")
    }
  }

  func testRejectsTenFullInstallationPages() async {
    let page = installationPage(count: 100, startingAt: 1)
    let transport = StubGitHubTransport(
      responses: Array(repeating: .json(status: 200, body: page), count: 10)
    )
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport
    )

    do {
      _ = try await client.listInstallations(jwt: "jwt")
      XCTFail("Expected pagination limit")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("too many results"))
    }
  }

  func testRejectsAggregateDescriptorBudgetBeforeEncodingBrokerFrame() async {
    let longLogin = String(repeating: "a", count: 2_000)
    let record = "{\"id\":1,\"account\":{\"login\":\"\(longLogin)\",\"type\":\"Organization\"},\"permissions\":{},\"suspended_at\":null}"
    let page = "[\(Array(repeating: record, count: 100).joined(separator: ","))]"
    let transport = StubGitHubTransport(
      responses: Array(repeating: .json(status: 200, body: page), count: 10)
    )
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport
    )

    do {
      _ = try await client.listInstallations(jwt: "jwt")
      XCTFail("Expected aggregate descriptor limit")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("more connection data"))
    }
  }

  func testPaginatesRepositoriesWithDownscopedInstallationToken() async throws {
    let transport = StubGitHubTransport(
      responses: [
        .json(status: 201, body: "{\"token\":\"token\"}"),
        .json(status: 200, body: repositoryPage(count: 100, startingAt: 1)),
        .json(status: 200, body: repositoryPage(count: 1, startingAt: 101)),
      ]
    )
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport
    )

    let repositories = try await client.listRepositories(installationID: 20, jwt: "jwt")

    XCTAssertEqual(repositories.count, 101)
    let requests = await transport.requests
    XCTAssertEqual(requests[2].url?.query, "per_page=100&page=2")
    XCTAssertEqual(
      requests[0].httpBody,
      Data("{\"permissions\":{\"metadata\":\"read\"}}".utf8)
    )
  }

  func testRejectsMalformedInstallationTokenResponse() async {
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: StubGitHubTransport(responses: [.json(status: 201, body: "{}")])
    )

    do {
      _ = try await client.listRepositories(installationID: 20, jwt: "jwt")
      XCTFail("Expected malformed token rejection")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("unreadable response"))
    }
  }

  func testExpiredOperationDeadlineSendsNoCredential() async {
    let transport = StubGitHubTransport(responses: [])
    let client = GitHubAppAPIClient(
      baseURL: URL(string: "https://api.github.test")!,
      transport: transport,
      operationTimeout: .zero
    )

    do {
      _ = try await client.listInstallations(jwt: "secret-jwt")
      XCTFail("Expected deadline failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("deadline"))
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testURLSessionTransportStopsAtStreamingBodyLimit() async throws {
    let configuration = URLSessionGitHubHTTPTransport.makeEphemeralConfiguration()
    configuration.protocolClasses = [StreamingGitHubURLProtocol.self]
    let fixture = StreamingGitHubURLProtocol.configure(
      responseData: Data(repeating: 0x61, count: 17),
      contentLength: nil
    )
    let transport = URLSessionGitHubHTTPTransport(
      session: URLSession(configuration: configuration)
    )
    let request = URLRequest(url: fixture.url)

    do {
      _ = try await transport.data(
        for: request,
        maximumBytes: 16,
        deadline: ContinuousClock.now.advanced(by: .seconds(1))
      )
      XCTFail("Expected streaming body limit")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("more connection data"))
    }
  }

  func testURLSessionTransportRejectsOversizedContentLengthBeforeBody() async throws {
    let configuration = URLSessionGitHubHTTPTransport.makeEphemeralConfiguration()
    configuration.protocolClasses = [StreamingGitHubURLProtocol.self]
    let fixture = StreamingGitHubURLProtocol.configure(responseData: Data(), contentLength: 17)
    let transport = URLSessionGitHubHTTPTransport(
      session: URLSession(configuration: configuration)
    )
    let request = URLRequest(url: fixture.url)

    do {
      _ = try await transport.data(
        for: request,
        maximumBytes: 16,
        deadline: ContinuousClock.now.advanced(by: .seconds(1))
      )
      XCTFail("Expected content length limit")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("more connection data"))
    }
  }

  func testURLSessionTransportCancelsStalledResponseAtMonotonicDeadline() async throws {
    let configuration = URLSessionGitHubHTTPTransport.makeEphemeralConfiguration()
    configuration.protocolClasses = [StreamingGitHubURLProtocol.self]
    let fixture = StreamingGitHubURLProtocol.configure(
      responseData: Data([0x61]),
      contentLength: nil,
      withholdCompletion: true
    )
    let transport = URLSessionGitHubHTTPTransport(
      session: URLSession(configuration: configuration)
    )
    let request = URLRequest(url: fixture.url)
    let started = ContinuousClock.now

    do {
      _ = try await transport.data(
        for: request,
        maximumBytes: 16,
        deadline: started.advanced(by: .milliseconds(50))
      )
      XCTFail("Expected deadline failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("deadline"), error.localizedDescription)
    }

    XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    await waitForStreamingProtocolStop(fixture.stopSignal)
    XCTAssertTrue(fixture.stopSignal.wasStopped)
  }

  func testURLSessionTransportCancelsRequestWithoutResponseAtMonotonicDeadline() async throws {
    let configuration = URLSessionGitHubHTTPTransport.makeEphemeralConfiguration()
    configuration.protocolClasses = [StreamingGitHubURLProtocol.self]
    let fixture = StreamingGitHubURLProtocol.configure(
      responseData: Data(),
      contentLength: nil,
      withholdCompletion: true,
      withholdResponse: true
    )
    let transport = URLSessionGitHubHTTPTransport(
      session: URLSession(configuration: configuration)
    )
    let request = URLRequest(url: fixture.url)
    let started = ContinuousClock.now

    do {
      _ = try await transport.data(
        for: request,
        maximumBytes: 16,
        deadline: started.advanced(by: .milliseconds(50))
      )
      XCTFail("Expected deadline failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("deadline"), error.localizedDescription)
    }

    XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    await waitForStreamingProtocolStop(fixture.stopSignal)
    XCTAssertTrue(fixture.stopSignal.wasStopped)
  }

  private func waitForStreamingProtocolStop(_ signal: StreamingProtocolStopSignal) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !signal.wasStopped, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func installationPage(count: Int, startingAt firstID: Int) -> String {
    let values = (firstID..<(firstID + count)).map { id in
      "{\"id\":\(id),\"account\":{\"login\":\"account-\(id)\",\"type\":\"Organization\"},\"permissions\":{\"issues\":\"read\",\"contents\":\"write\"},\"suspended_at\":null}"
    }
    return "[\(values.joined(separator: ","))]"
  }

  private func repositoryPage(count: Int, startingAt firstID: Int) -> String {
    let values = (firstID..<(firstID + count)).map { id in
      "{\"id\":\(id),\"full_name\":\"octo/repository-\(id)\",\"html_url\":\"https://github.com/octo/repository-\(id)\",\"private\":true}"
    }
    return "{\"repositories\":[\(values.joined(separator: ","))]}"
  }

  private func makeRepositoryScope() throws -> AuthorizedGitHubRepositoryScope {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("github-api-scope-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try AuthorizedGitHubRepositoryScope(
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
  }
}

private final class StreamingGitHubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Fixture {
    let url: URL
    let stopSignal: StreamingProtocolStopSignal
  }

  private struct FixtureState {
    let responseData: Data
    let contentLength: Int?
    let withholdCompletion: Bool
    let withholdResponse: Bool
    let stopSignal: StreamingProtocolStopSignal
  }

  private static let stateLock = NSLock()
  nonisolated(unsafe) private static var fixtures: [String: FixtureState] = [:]
  private let signalLock = NSLock()
  private var stopSignal: StreamingProtocolStopSignal?

  static func configure(
    responseData: Data,
    contentLength: Int?,
    withholdCompletion: Bool = false,
    withholdResponse: Bool = false
  ) -> Fixture {
    let url = URL(string: "https://api.github.test/fixture/\(UUID().uuidString)")!
    let stopSignal = StreamingProtocolStopSignal()
    stateLock.withLock {
      fixtures[url.absoluteString] = FixtureState(
        responseData: responseData,
        contentLength: contentLength,
        withholdCompletion: withholdCompletion,
        withholdResponse: withholdResponse,
        stopSignal: stopSignal
      )
    }
    return Fixture(url: url, stopSignal: stopSignal)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    guard let fixture = Self.stateLock.withLock({ Self.fixtures.removeValue(forKey: url.absoluteString) }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    signalLock.withLock { stopSignal = fixture.stopSignal }
    if fixture.withholdResponse { return }
    var headers: [String: String] = ["Content-Type": "application/json"]
    if let contentLength = fixture.contentLength {
      headers["Content-Length"] = String(contentLength)
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !fixture.responseData.isEmpty {
      client?.urlProtocol(self, didLoad: fixture.responseData)
    }
    if !fixture.withholdCompletion {
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {
    signalLock.withLock { stopSignal }?.markStopped()
  }
}

private final class StreamingProtocolStopSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false

  var wasStopped: Bool { lock.withLock { stopped } }

  func markStopped() {
    lock.withLock { stopped = true }
  }
}

private struct FailingGitHubTransport: GitHubHTTPTransporting {
  func data(
    for request: URLRequest,
    maximumBytes: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> (Data, HTTPURLResponse) {
    throw URLError(.notConnectedToInternet)
  }
}

private actor StubGitHubTransport: GitHubHTTPTransporting {
  struct Response {
    let status: Int
    let data: Data

    static func json(status: Int, body: String) -> Self {
      Self(status: status, data: Data(body.utf8))
    }
  }

  private var responses: [Response]
  private(set) var requests: [URLRequest] = []

  init(responses: [Response]) {
    self.responses = responses
  }

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
