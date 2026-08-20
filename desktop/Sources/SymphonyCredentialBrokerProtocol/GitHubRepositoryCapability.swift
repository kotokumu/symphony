import Foundation

public struct GitHubRepositoryAuthorization: Codable, Equatable, Sendable {
  public let appID: Int64
  public let installationID: Int64
  public let repositoryID: Int64
  public let repositoryFullName: String
  public let repositoryURL: URL
  public let workspacesRoot: URL

  public init(
    appID: Int64,
    installationID: Int64,
    repositoryID: Int64,
    repositoryFullName: String,
    repositoryURL: URL,
    workspacesRoot: URL
  ) {
    self.appID = appID
    self.installationID = installationID
    self.repositoryID = repositoryID
    self.repositoryFullName = repositoryFullName
    self.repositoryURL = repositoryURL
    self.workspacesRoot = workspacesRoot
  }
}

public enum GitHubIssueState: String, Codable, Equatable, Sendable {
  case open
  case closed
}

public struct GitHubPage: Codable, Equatable, Sendable {
  public static let `default` = GitHubPage(uncheckedPerPage: 30, page: 1)
  public let perPage: Int32
  public let page: Int32

  public init(perPage: Int32 = 30, page: Int32 = 1) throws {
    guard (1...100).contains(perPage), page > 0 else {
      throw GitHubCapabilityProtocolError.invalidPage
    }
    self.perPage = perPage
    self.page = page
  }

  private init(uncheckedPerPage perPage: Int32, page: Int32) {
    self.perPage = perPage
    self.page = page
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try Self.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
    try self.init(
      perPage: container.decodeIfPresent(Int32.self, forKey: .perPage) ?? 30,
      page: container.decodeIfPresent(Int32.self, forKey: .page) ?? 1
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case perPage, page
  }

  fileprivate static func rejectUnknownKeys(
    in decoder: any Decoder,
    allowed: [String]
  ) throws {
    let values = try decoder.container(keyedBy: AnyCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)).isSubset(of: Set(allowed)) else {
      throw GitHubCapabilityProtocolError.unknownField
    }
  }
}

public struct GitHubIssueListQuery: Codable, Equatable, Sendable {
  public enum State: String, Codable, Equatable, Sendable {
    case open
    case closed
    case all
  }

  public let state: State
  public let labels: [String]
  public let assignee: String?
  public let since: String?
  public let pagination: GitHubPage

  public init(
    state: State = .open,
    labels: [String] = [],
    assignee: String? = nil,
    since: String? = nil,
    pagination: GitHubPage = .default
  ) throws {
    guard labels.count <= 100,
      labels.allSatisfy(Self.isValidLabel),
      Set(labels).count == labels.count
    else {
      throw GitHubCapabilityProtocolError.invalidLabels
    }
    if let assignee, !Self.isValidText(assignee, maximumBytes: 100) {
      throw GitHubCapabilityProtocolError.invalidAssignee
    }
    if let since, !Self.isRFC3339(since) {
      throw GitHubCapabilityProtocolError.invalidSince
    }
    self.state = state
    self.labels = labels
    self.assignee = assignee
    self.since = since
    self.pagination = pagination
  }

  public init(from decoder: any Decoder) throws {
    try GitHubPage.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      state: container.decodeIfPresent(State.self, forKey: .state) ?? .open,
      labels: container.decodeIfPresent([String].self, forKey: .labels) ?? [],
      assignee: container.decodeIfPresent(String.self, forKey: .assignee),
      since: container.decodeIfPresent(String.self, forKey: .since),
      pagination: container.decodeIfPresent(GitHubPage.self, forKey: .pagination)
        ?? .default
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case state, labels, assignee, since, pagination
  }

  private static func isValidLabel(_ value: String) -> Bool {
    isValidText(value, maximumBytes: 100) && !value.contains(",")
  }

  private static func isValidText(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  private static func isRFC3339(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) != nil
  }
}

public enum GitHubIssueCapabilityRequest: Codable, Equatable, Sendable {
  case listIssues(GitHubIssueListQuery)
  case getIssue(issueNumber: Int32)
  case listComments(issueNumber: Int32, page: GitHubPage)
  case createComment(issueNumber: Int32, body: String)
  case setIssueState(issueNumber: Int32, state: GitHubIssueState)

  private enum Operation: String, Codable {
    case listIssues, getIssue, listComments, createComment, setIssueState
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case operation, query, issueNumber, page, body, state
  }

  public init(from decoder: any Decoder) throws {
    try GitHubPage.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let operation = try container.decode(Operation.self, forKey: .operation)
    switch operation {
    case .listIssues:
      try Self.requireKeys(container, exactly: [.operation, .query])
      self = .listIssues(try container.decode(GitHubIssueListQuery.self, forKey: .query))
    case .getIssue:
      try Self.requireKeys(container, exactly: [.operation, .issueNumber])
      self = .getIssue(issueNumber: try Self.issueNumber(container))
    case .listComments:
      try Self.requireKeys(container, exactly: [.operation, .issueNumber, .page])
      self = .listComments(
        issueNumber: try Self.issueNumber(container),
        page: try container.decode(GitHubPage.self, forKey: .page)
      )
    case .createComment:
      try Self.requireKeys(container, exactly: [.operation, .issueNumber, .body])
      let body = try container.decode(String.self, forKey: .body)
      guard !body.isEmpty, body.utf8.count <= 32_768 else {
        throw GitHubCapabilityProtocolError.invalidComment
      }
      self = .createComment(issueNumber: try Self.issueNumber(container), body: body)
    case .setIssueState:
      try Self.requireKeys(container, exactly: [.operation, .issueNumber, .state])
      self = .setIssueState(
        issueNumber: try Self.issueNumber(container),
        state: try container.decode(GitHubIssueState.self, forKey: .state)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .listIssues(let query):
      try container.encode(Operation.listIssues, forKey: .operation)
      try container.encode(query, forKey: .query)
    case .getIssue(let issueNumber):
      try Self.validate(issueNumber)
      try container.encode(Operation.getIssue, forKey: .operation)
      try container.encode(issueNumber, forKey: .issueNumber)
    case .listComments(let issueNumber, let page):
      try Self.validate(issueNumber)
      try container.encode(Operation.listComments, forKey: .operation)
      try container.encode(issueNumber, forKey: .issueNumber)
      try container.encode(page, forKey: .page)
    case .createComment(let issueNumber, let body):
      try Self.validate(issueNumber)
      guard !body.isEmpty, body.utf8.count <= 32_768 else {
        throw GitHubCapabilityProtocolError.invalidComment
      }
      try container.encode(Operation.createComment, forKey: .operation)
      try container.encode(issueNumber, forKey: .issueNumber)
      try container.encode(body, forKey: .body)
    case .setIssueState(let issueNumber, let state):
      try Self.validate(issueNumber)
      try container.encode(Operation.setIssueState, forKey: .operation)
      try container.encode(issueNumber, forKey: .issueNumber)
      try container.encode(state, forKey: .state)
    }
  }

  private static func issueNumber(
    _ container: KeyedDecodingContainer<CodingKeys>
  ) throws -> Int32 {
    let number = try container.decode(Int32.self, forKey: .issueNumber)
    try validate(number)
    return number
  }

  private static func validate(_ issueNumber: Int32) throws {
    guard issueNumber > 0 else { throw GitHubCapabilityProtocolError.invalidIssueNumber }
  }

  private static func requireKeys(
    _ container: KeyedDecodingContainer<CodingKeys>,
    exactly expected: Set<CodingKeys>
  ) throws {
    guard Set(container.allKeys) == expected else {
      throw GitHubCapabilityProtocolError.invalidPayload
    }
  }
}

public struct GitHubIssueCapabilityResponse: Codable, Equatable, Sendable {
  public let status: Int
  public let body: Data

  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}

public enum GitRepositoryCapabilityRequest: Codable, Equatable, Sendable {
  case clone(targetName: String)
  case fetch(repositoryName: String)
  case push(repositoryName: String, branch: String)
}

public struct GitRepositoryCapabilityResult: Codable, Equatable, Sendable {
  public let exitStatus: Int32
  public let output: String
  public let wasTruncated: Bool

  public init(exitStatus: Int32, output: String, wasTruncated: Bool) {
    self.exitStatus = exitStatus
    self.output = output
    self.wasTruncated = wasTruncated
  }
}

public struct GitHubCapabilityFailure: Codable, Equatable, Sendable {
  public enum Category: String, Codable, Sendable {
    case locked, unauthorizedScope, invalidRequest, authExpired
    case appCredentialRejected, installationRevoked, repositoryUnavailable
    case resourceNotFound, permissionDenied, rateLimited
    case networkUnavailable, timedOut, serviceUnavailable, invalidServiceResponse
    case redirectRejected, ambiguousMutationAuthenticationFailure
    case gitFailed, gitAuthenticationRejected, gitOutputTooLarge, cleanupRequired
  }

  public let category: Category
  public let message: String
  public let status: Int?
  public let retryAt: Date?
  public let effectMayHaveOccurred: Bool

  public init(
    category: Category,
    message: String,
    status: Int? = nil,
    retryAt: Date? = nil,
    effectMayHaveOccurred: Bool = false
  ) {
    self.category = category
    self.message = message
    self.status = status
    self.retryAt = retryAt
    self.effectMayHaveOccurred = effectMayHaveOccurred
  }
}

public enum GitHubCapabilityProtocolError: LocalizedError, Equatable, Sendable {
  case invalidPage, invalidLabels, invalidAssignee, invalidSince
  case invalidIssueNumber, invalidComment, invalidPayload, unknownField

  public var errorDescription: String? {
    "The GitHub capability request is invalid."
  }
}

private struct AnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}
