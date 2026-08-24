import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit
@testable import SymphonyCredentialBrokerProtocol

final class GitRepositoryTrustPolicyTests: XCTestCase {
  func testCloneAcceptsOnlyAnAbsentDirectChild() throws {
    let fixture = try makeFixture()
    let policy = GitRepositoryTrustPolicy()

    let plan = try policy.validate(.clone(targetName: "issue-7"), in: fixture.scope)
    XCTAssertEqual(plan.targetURL.lastPathComponent, "issue-7")
    XCTAssertEqual(plan.arguments.first, "clone")

    for name in ["", ".", "..", "nested/repo", "bad\nname"] {
      XCTAssertThrowsError(try policy.validate(.clone(targetName: name), in: fixture.scope))
    }
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent("exists"),
      withIntermediateDirectories: false
    )
    XCTAssertThrowsError(try policy.validate(.clone(targetName: "exists"), in: fixture.scope))
  }

  func testFetchAndPushUseTheAuthorizedURLInsteadOfConfiguredPushDestinations() throws {
    let fixture = try makeFixture(repositoryName: "repo")
    let policy = GitRepositoryTrustPolicy()

    let fetch = try policy.validate(.fetch(repositoryName: "repo"), in: fixture.scope)
    let push = try policy.validate(
      .push(repositoryName: "repo", branch: "feature/issue-7"),
      in: fixture.scope
    )

    XCTAssertTrue(fetch.arguments.contains("https://github.com/octo/repo"))
    XCTAssertTrue(push.arguments.contains("HEAD:refs/heads/feature/issue-7"))
    XCTAssertFalse(push.arguments.contains("origin"))
  }

  func testRejectsUnsafeLocalConfigurationBeforeCredentialAcquisition() throws {
    let hostile = [
      "[remote \"origin\"]\n  url = https://github.com/octo/repo\n  pushurl = https://github.com/other/repo\n",
      "[remote \"origin\"]\n  url = https://github.com/octo/repo\n[credential]\n  helper = store\n",
      "[remote \"origin\"]\n  url = https://github.com/octo/repo\n[url \"https://evil.test/\"]\n  insteadOf = https://github.com/\n",
      "[remote \"origin\"]\n  url = https://github.com/octo/repo\n[http]\n  proxy = http://localhost:9999\n",
      "[remote \"origin\"]\n  url = https://github.com/other/repo\n",
    ]

    for config in hostile {
      let fixture = try makeFixture(repositoryName: "repo", config: config)
      XCTAssertThrowsError(
        try GitRepositoryTrustPolicy().validate(.fetch(repositoryName: "repo"), in: fixture.scope),
        config
      )
    }
  }

  func testRejectsGitdirIndirectionAlternatesAndSymlinks() throws {
    for forbidden in ["commondir", "gitdir", "objects/info/alternates"] {
      let fixture = try makeFixture(repositoryName: "repo")
      let path = fixture.root.appendingPathComponent("repo/.git/\(forbidden)")
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      FileManager.default.createFile(atPath: path.path, contents: Data("outside".utf8))
      XCTAssertThrowsError(
        try GitRepositoryTrustPolicy().validate(.fetch(repositoryName: "repo"), in: fixture.scope)
      )
    }

    let symlink = try makeFixture(repositoryName: "repo")
    try FileManager.default.createSymbolicLink(
      at: symlink.root.appendingPathComponent("repo/.git/escape"),
      withDestinationURL: URL(fileURLWithPath: "/tmp")
    )
    XCTAssertThrowsError(
      try GitRepositoryTrustPolicy().validate(.fetch(repositoryName: "repo"), in: symlink.scope)
    )
  }

  func testBranchGrammarMatchesTheScopedPushContract() {
    for value in ["main", "feature/issue-7", "release_1.2"] {
      XCTAssertTrue(GitRepositoryTrustPolicy.isValidBranch(value), value)
    }
    for value in ["", "@", ".hidden", "a/.hidden", "../main", "a..b", "a//b", "a.lock", "-main", "main."] {
      XCTAssertFalse(GitRepositoryTrustPolicy.isValidBranch(value), value)
    }
  }

  private func makeFixture(
    repositoryName: String? = nil,
    config: String? = nil
  ) throws -> (root: URL, scope: AuthorizedGitHubRepositoryScope) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-git-policy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    if let repositoryName {
      let metadata = root.appendingPathComponent("\(repositoryName)/.git", isDirectory: true)
      try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
      let normal = """
        [core]
          repositoryformatversion = 0
          filemode = true
          bare = false
          logallrefupdates = true
        [remote "origin"]
          url = https://github.com/octo/repo.git
          fetch = +refs/heads/*:refs/remotes/origin/*
        """
      try Data((config ?? normal).utf8).write(to: metadata.appendingPathComponent("config"))
    }
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
