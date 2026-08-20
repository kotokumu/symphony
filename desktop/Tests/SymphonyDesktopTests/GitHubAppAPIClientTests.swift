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
