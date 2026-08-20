import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit

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
    StreamingGitHubURLProtocol.responseData = Data(repeating: 0x61, count: 17)
    StreamingGitHubURLProtocol.contentLength = nil
    StreamingGitHubURLProtocol.withholdCompletion = false
    StreamingGitHubURLProtocol.wasStopped = false
    let transport = URLSessionGitHubHTTPTransport(
      session: URLSession(configuration: configuration)
    )
    let request = URLRequest(url: URL(string: "https://api.github.test/data")!)

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
    StreamingGitHubURLProtocol.responseData = Data()
    StreamingGitHubURLProtocol.contentLength = 17
    StreamingGitHubURLProtocol.withholdCompletion = false
    StreamingGitHubURLProtocol.wasStopped = false
    let transport = URLSessionGitHubHTTPTransport(
      session: URLSession(configuration: configuration)
    )
    let request = URLRequest(url: URL(string: "https://api.github.test/data")!)

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
    StreamingGitHubURLProtocol.responseData = Data([0x61])
    StreamingGitHubURLProtocol.contentLength = nil
    StreamingGitHubURLProtocol.withholdCompletion = true
    StreamingGitHubURLProtocol.wasStopped = false
    defer { StreamingGitHubURLProtocol.withholdCompletion = false }
    let transport = URLSessionGitHubHTTPTransport(
      session: URLSession(configuration: configuration)
    )
    let request = URLRequest(url: URL(string: "https://api.github.test/data")!)
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
    XCTAssertTrue(StreamingGitHubURLProtocol.wasStopped)
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
}

private final class StreamingGitHubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var responseData = Data()
  nonisolated(unsafe) static var contentLength: Int?
  nonisolated(unsafe) static var withholdCompletion = false
  nonisolated(unsafe) static var wasStopped = false

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var headers: [String: String] = ["Content-Type": "application/json"]
    if let contentLength = Self.contentLength {
      headers["Content-Length"] = String(contentLength)
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !Self.responseData.isEmpty {
      client?.urlProtocol(self, didLoad: Self.responseData)
    }
    if !Self.withholdCompletion {
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() { Self.wasStopped = true }
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
