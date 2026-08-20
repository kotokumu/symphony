import Foundation

public enum CredentialBrokerProtocolLimits {
  public static let maximumCommandBytes = 65_536
  public static let maximumResponseBytes = 1_048_576
  public static let maximumGitHubDescriptorBytes = 1_000_000
  public static let defaultGitHubOperationTimeout: Duration = .seconds(50)
  public static let defaultCapabilityTimeout: TimeInterval = 60
  public static let maximumGitHubAPIResponseBytes = 512 * 1_024
  public static let maximumGitOutputBytes = 65_536
  public static let maximumGitCredentialInputBytes = 16_384
}

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
    case authorizeGitHubRepository
    case performGitHubIssueRequest
    case performGitHubGitOperation
    case lock
  }

  public let operation: Operation
  public let payload: Data?
  public let githubAppConfiguration: GitHubAppConfigurationRequest?
  public let installationID: Int64?
  public let githubRepositoryAuthorization: GitHubRepositoryAuthorization?
  public let githubIssueRequest: GitHubIssueCapabilityRequest?
  public let githubGitRequest: GitRepositoryCapabilityRequest?

  public init(
    operation: Operation,
    payload: Data? = nil,
    githubAppConfiguration: GitHubAppConfigurationRequest? = nil,
    installationID: Int64? = nil,
    githubRepositoryAuthorization: GitHubRepositoryAuthorization? = nil,
    githubIssueRequest: GitHubIssueCapabilityRequest? = nil,
    githubGitRequest: GitRepositoryCapabilityRequest? = nil
  ) {
    self.operation = operation
    self.payload = payload
    self.githubAppConfiguration = githubAppConfiguration
    self.installationID = installationID
    self.githubRepositoryAuthorization = githubRepositoryAuthorization
    self.githubIssueRequest = githubIssueRequest
    self.githubGitRequest = githubGitRequest
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

  public static func authorizeGitHubRepository(_ authorization: GitHubRepositoryAuthorization) -> Self {
    Self(
      operation: .authorizeGitHubRepository,
      githubRepositoryAuthorization: authorization
    )
  }

  public static func performGitHubIssueRequest(_ request: GitHubIssueCapabilityRequest) -> Self {
    Self(operation: .performGitHubIssueRequest, githubIssueRequest: request)
  }

  public static func performGitHubGitOperation(_ request: GitRepositoryCapabilityRequest) -> Self {
    Self(operation: .performGitHubGitOperation, githubGitRequest: request)
  }

  public func validatePayloadShape() throws {
    let values: [Bool] = [
      payload != nil,
      githubAppConfiguration != nil,
      installationID != nil,
      githubRepositoryAuthorization != nil,
      githubIssueRequest != nil,
      githubGitRequest != nil,
    ]
    let expectedIndex: Int?
    switch operation {
    case .signChallenge: expectedIndex = 0
    case .configureGitHubApp: expectedIndex = 1
    case .listGitHubInstallations, .lock: expectedIndex = nil
    case .listGitHubRepositories: expectedIndex = 2
    case .authorizeGitHubRepository: expectedIndex = 3
    case .performGitHubIssueRequest: expectedIndex = 4
    case .performGitHubGitOperation: expectedIndex = 5
    }
    guard values.enumerated().allSatisfy({ index, isPresent in
      isPresent == (index == expectedIndex)
    }) else {
      throw GitHubCapabilityProtocolError.invalidPayload
    }
  }
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
  case githubRepositoryAuthorized
  case githubIssueResponse(GitHubIssueCapabilityResponse)
  case githubGitResult(GitRepositoryCapabilityResult)
  case githubCapabilityFailed(GitHubCapabilityFailure)
  case locked
  case failed(message: String)

  private enum CodingKeys: String, CodingKey {
    case status
    case payload
    case installations
    case repositories
    case githubIssueResponse
    case githubGitResult
    case githubCapabilityFailure
    case message
  }

  private enum Status: String, Codable {
    case signature
    case githubAppConfigured
    case githubInstallations
    case githubRepositories
    case githubRepositoryAuthorized
    case githubIssueResponse
    case githubGitResult
    case githubCapabilityFailed
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
    case .githubRepositoryAuthorized:
      self = .githubRepositoryAuthorized
    case .githubIssueResponse:
      self = .githubIssueResponse(
        try container.decode(GitHubIssueCapabilityResponse.self, forKey: .githubIssueResponse)
      )
    case .githubGitResult:
      self = .githubGitResult(
        try container.decode(GitRepositoryCapabilityResult.self, forKey: .githubGitResult)
      )
    case .githubCapabilityFailed:
      self = .githubCapabilityFailed(
        try container.decode(GitHubCapabilityFailure.self, forKey: .githubCapabilityFailure)
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
    case .githubRepositoryAuthorized:
      try container.encode(Status.githubRepositoryAuthorized, forKey: .status)
    case .githubIssueResponse(let response):
      try container.encode(Status.githubIssueResponse, forKey: .status)
      try container.encode(response, forKey: .githubIssueResponse)
    case .githubGitResult(let result):
      try container.encode(Status.githubGitResult, forKey: .status)
      try container.encode(result, forKey: .githubGitResult)
    case .githubCapabilityFailed(let failure):
      try container.encode(Status.githubCapabilityFailed, forKey: .status)
      try container.encode(failure, forKey: .githubCapabilityFailure)
    case .locked:
      try container.encode(Status.locked, forKey: .status)
    case .failed(let message):
      try container.encode(Status.failed, forKey: .status)
      try container.encode(message, forKey: .message)
    }
  }
}
