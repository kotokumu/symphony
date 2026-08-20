import Foundation

public enum PlatformConnection: Hashable, Sendable {
  case github(GitHubConnection)
}

public struct GitHubConnection: Hashable, Sendable {
  public let appID: Int64
  public let installationID: Int64
  public let accountLogin: String
  public let repositoryID: Int64
  public let repositoryFullName: String
  public let repositoryURL: URL

  public init(
    appID: Int64,
    installationID: Int64,
    accountLogin: String,
    repositoryID: Int64,
    repositoryFullName: String,
    repositoryURL: URL
  ) throws {
    guard appID > 0, installationID > 0, repositoryID > 0 else {
      throw GitHubConnectionError.invalidIdentity
    }
    guard !accountLogin.isEmpty, !repositoryFullName.isEmpty else {
      throw GitHubConnectionError.invalidIdentity
    }
    guard repositoryURL.scheme == "https", repositoryURL.host == "github.com" else {
      throw GitHubConnectionError.invalidRepositoryURL
    }

    self.appID = appID
    self.installationID = installationID
    self.accountLogin = accountLogin
    self.repositoryID = repositoryID
    self.repositoryFullName = repositoryFullName
    self.repositoryURL = repositoryURL
  }
}

public enum GitHubConnectionError: LocalizedError, Equatable, Sendable {
  case invalidIdentity
  case invalidRepositoryURL

  public var errorDescription: String? {
    switch self {
    case .invalidIdentity:
      "The GitHub App connection contains an invalid identity. Choose the installation again."
    case .invalidRepositoryURL:
      "The selected repository does not have a valid GitHub URL."
    }
  }
}
