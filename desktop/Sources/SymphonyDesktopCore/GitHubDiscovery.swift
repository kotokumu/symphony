import Foundation

public struct GitHubInstallation: Equatable, Identifiable, Sendable {
  public let id: Int64
  public let accountLogin: String
  public let accountType: String
  public let permissions: [String: String]
  public let isSuspended: Bool

  public init(
    id: Int64,
    accountLogin: String,
    accountType: String,
    permissions: [String: String],
    isSuspended: Bool
  ) {
    self.id = id
    self.accountLogin = accountLogin
    self.accountType = accountType
    self.permissions = permissions
    self.isSuspended = isSuspended
  }
}

public struct GitHubRepository: Equatable, Identifiable, Sendable {
  public let id: Int64
  public let fullName: String
  public let htmlURL: URL
  public let isPrivate: Bool

  public init(id: Int64, fullName: String, htmlURL: URL, isPrivate: Bool) {
    self.id = id
    self.fullName = fullName
    self.htmlURL = htmlURL
    self.isPrivate = isPrivate
  }
}
