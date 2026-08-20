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

  private func installationPage(count: Int, startingAt firstID: Int) -> String {
    let values = (firstID..<(firstID + count)).map { id in
      "{\"id\":\(id),\"account\":{\"login\":\"account-\(id)\",\"type\":\"Organization\"},\"permissions\":{\"issues\":\"read\",\"contents\":\"write\"},\"suspended_at\":null}"
    }
    return "[\(values.joined(separator: ","))]"
  }
}

private struct FailingGitHubTransport: GitHubHTTPTransporting {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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

  func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
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
