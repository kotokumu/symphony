import Foundation
import XCTest

@testable import SymphonyCredentialBrokerProtocol

final class GitHubRepositoryCapabilityProtocolTests: XCTestCase {
  func testRoundTripsEveryIssueCapabilityAsOneClosedPayloadShape() throws {
    let values: [GitHubIssueCapabilityRequest] = [
      .listIssues(
        try GitHubIssueListQuery(
          state: .all,
          labels: ["desktop", "重要"],
          assignee: "octocat",
          since: "2026-08-20T00:00:00Z",
          pagination: try GitHubPage(perPage: 100, page: 2)
        )
      ),
      .getIssue(issueNumber: 7),
      .listComments(issueNumber: 7, page: try GitHubPage()),
      .createComment(issueNumber: 7, body: "done"),
      .setIssueState(issueNumber: 7, state: .closed),
    ]

    for value in values {
      let encoded = try JSONEncoder().encode(value)
      XCTAssertEqual(try JSONDecoder().decode(GitHubIssueCapabilityRequest.self, from: encoded), value)
    }
  }

  func testRejectsUnknownFieldsInvalidCombinationsAndBoundsWhileDecoding() {
    let invalid = [
      #"{"operation":"getIssue","issueNumber":1,"body":"extra"}"#,
      #"{"operation":"getIssue","issueNumber":0}"#,
      #"{"operation":"listComments","issueNumber":1,"page":{"perPage":101,"page":1}}"#,
      #"{"operation":"createComment","issueNumber":1,"body":""}"#,
      #"{"operation":"listIssues","query":{"state":"open","labels":["a,a"],"pagination":{"perPage":30,"page":1}}}"#,
      #"{"operation":"unknown"}"#,
    ]

    for json in invalid {
      XCTAssertThrowsError(
        try JSONDecoder().decode(GitHubIssueCapabilityRequest.self, from: Data(json.utf8)),
        json
      )
    }
  }

  func testEncodesCapabilityCommandsWithoutNamespaceOrRawRepositoryAuthority() throws {
    let authorization = GitHubRepositoryAuthorization(
      appID: 10,
      installationID: 20,
      repositoryID: 30,
      repositoryFullName: "octo/repo",
      repositoryURL: URL(string: "https://github.com/octo/repo")!,
      workspacesRoot: URL(fileURLWithPath: "/tmp/workspaces")
    )
    let authorized = try JSONEncoder().encode(
      CredentialBrokerCommand.authorizeGitHubRepository(authorization)
    )
    let issue = try JSONEncoder().encode(
      CredentialBrokerCommand.performGitHubIssueRequest(.getIssue(issueNumber: 9))
    )

    XCTAssertTrue(String(decoding: authorized, as: UTF8.self).contains("repositoryID"))
    XCTAssertFalse(String(decoding: issue, as: UTF8.self).contains("namespace"))
    XCTAssertFalse(String(decoding: issue, as: UTF8.self).contains("github.com"))
    XCTAssertFalse(String(decoding: issue, as: UTF8.self).contains("octo"))
  }
}
