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

  func testRejectsUnknownAuthorityFieldsAtEveryBrokerFrame() {
    let commandFrames = [
      #"{"operation":"performGitHubIssueRequest","githubIssueRequest":{"operation":"getIssue","issueNumber":1},"namespace":"other"}"#,
      #"{"operation":"performGitHubGitOperation","githubGitRequest":{"clone":{"targetName":"x"}},"token":"secret"}"#,
      #"{"operation":"authorizeGitHubRepository","githubRepositoryAuthorization":{"appID":10,"installationID":20,"repositoryID":30,"repositoryFullName":"octo/repo","repositoryURL":"https:\/\/github.com\/octo\/repo","workspacesRoot":"file:\/\/\/tmp\/workspaces","override":"other\/repo"}}"#,
    ]
    for frame in commandFrames {
      XCTAssertThrowsError(
        try JSONDecoder().decode(CredentialBrokerCommand.self, from: Data(frame.utf8)),
        frame
      )
    }

    let resultFrames = [
      #"{"status":"locked","payload":"c2VjcmV0"}"#,
      #"{"status":"githubGitResult","githubGitResult":{"exitStatus":0,"output":"","wasTruncated":false,"token":"secret"}}"#,
      #"{"status":"githubCapabilityFailed","githubCapabilityFailure":{"category":"locked","message":"locked","effectMayHaveOccurred":false,"repository":"other"}}"#,
      #"{"status":"githubInstallations","installations":[{"id":20,"accountLogin":"octo","accountType":"Organization","permissions":{},"isSuspended":false,"token":"secret"}]}"#,
      #"{"status":"githubRepositories","repositories":[{"id":30,"fullName":"octo/repo","htmlURL":"https:\/\/github.com\/octo\/repo","isPrivate":true,"token":"secret"}]}"#,
    ]
    for frame in resultFrames {
      XCTAssertThrowsError(
        try JSONDecoder().decode(CredentialBrokerResult.self, from: Data(frame.utf8)),
        frame
      )
    }
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        CredentialBrokerHandshake.self,
        from: Data(#"{"status":"unlocked","token":"secret"}"#.utf8)
      )
    )
  }
}
