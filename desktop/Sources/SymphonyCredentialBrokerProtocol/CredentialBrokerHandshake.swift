import Foundation

public enum CredentialBrokerHandshake: Codable, Equatable, Sendable {
  case unlocked
  case failed(message: String)

  private enum CodingKeys: String, CodingKey {
    case status
    case message
  }

  private enum Status: String, Codable {
    case unlocked
    case failed
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Status.self, forKey: .status) {
    case .unlocked:
      self = .unlocked
    case .failed:
      self = .failed(message: try container.decode(String.self, forKey: .message))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .unlocked:
      try container.encode(Status.unlocked, forKey: .status)
    case .failed(let message):
      try container.encode(Status.failed, forKey: .status)
      try container.encode(message, forKey: .message)
    }
  }
}

public struct CredentialBrokerCommand: Codable, Equatable, Sendable {
  public enum Operation: String, Codable, Sendable {
    case signChallenge
    case configureGitHubApp
    case listGitHubInstallations
    case listGitHubRepositories
    case lock
  }

  public let operation: Operation
  public let payload: Data?
  public let githubAppConfiguration: GitHubAppConfigurationRequest?
  public let installationID: Int64?

  public init(
    operation: Operation,
    payload: Data? = nil,
    githubAppConfiguration: GitHubAppConfigurationRequest? = nil,
    installationID: Int64? = nil
  ) {
    self.operation = operation
    self.payload = payload
    self.githubAppConfiguration = githubAppConfiguration
    self.installationID = installationID
  }

  public static func signChallenge(_ challenge: Data) -> Self {
    Self(operation: .signChallenge, payload: challenge)
  }

  public static func configureGitHubApp(
    appID: Int64,
    privateKeyFilePath: String
  ) -> Self {
    Self(
      operation: .configureGitHubApp,
      githubAppConfiguration: GitHubAppConfigurationRequest(
        appID: appID,
        privateKeyFilePath: privateKeyFilePath
      )
    )
  }

  public static let listGitHubInstallations = Self(operation: .listGitHubInstallations)

  public static func listGitHubRepositories(installationID: Int64) -> Self {
    Self(operation: .listGitHubRepositories, installationID: installationID)
  }

  public static let lock = Self(operation: .lock)
}

public struct GitHubAppConfigurationRequest: Codable, Equatable, Sendable {
  public let appID: Int64
  public let privateKeyFilePath: String

  public init(appID: Int64, privateKeyFilePath: String) {
    self.appID = appID
    self.privateKeyFilePath = privateKeyFilePath
  }
}

public struct GitHubInstallationDescriptor: Codable, Equatable, Identifiable, Sendable {
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

public struct GitHubRepositoryDescriptor: Codable, Equatable, Identifiable, Sendable {
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

public enum CredentialBrokerResult: Codable, Equatable, Sendable {
  case signature(Data)
  case githubAppConfigured
  case githubInstallations([GitHubInstallationDescriptor])
  case githubRepositories([GitHubRepositoryDescriptor])
  case locked
  case failed(message: String)

  private enum CodingKeys: String, CodingKey {
    case status
    case payload
    case installations
    case repositories
    case message
  }

  private enum Status: String, Codable {
    case signature
    case githubAppConfigured
    case githubInstallations
    case githubRepositories
    case locked
    case failed
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Status.self, forKey: .status) {
    case .signature:
      self = .signature(try container.decode(Data.self, forKey: .payload))
    case .githubAppConfigured:
      self = .githubAppConfigured
    case .githubInstallations:
      self = .githubInstallations(
        try container.decode([GitHubInstallationDescriptor].self, forKey: .installations)
      )
    case .githubRepositories:
      self = .githubRepositories(
        try container.decode([GitHubRepositoryDescriptor].self, forKey: .repositories)
      )
    case .locked:
      self = .locked
    case .failed:
      self = .failed(message: try container.decode(String.self, forKey: .message))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .signature(let signature):
      try container.encode(Status.signature, forKey: .status)
      try container.encode(signature, forKey: .payload)
    case .githubAppConfigured:
      try container.encode(Status.githubAppConfigured, forKey: .status)
    case .githubInstallations(let installations):
      try container.encode(Status.githubInstallations, forKey: .status)
      try container.encode(installations, forKey: .installations)
    case .githubRepositories(let repositories):
      try container.encode(Status.githubRepositories, forKey: .status)
      try container.encode(repositories, forKey: .repositories)
    case .locked:
      try container.encode(Status.locked, forKey: .status)
    case .failed(let message):
      try container.encode(Status.failed, forKey: .status)
      try container.encode(message, forKey: .message)
    }
  }
}
