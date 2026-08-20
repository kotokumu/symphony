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

  public init(from decoder: any Decoder) throws {
    try StrictProtocolCoding.rejectUnknownKeys(
      in: decoder,
      allowed: CodingKeys.allCases.map(\.stringValue)
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      appID: try container.decode(Int64.self, forKey: .appID),
      installationID: try container.decode(Int64.self, forKey: .installationID),
      repositoryID: try container.decode(Int64.self, forKey: .repositoryID),
      repositoryFullName: try container.decode(String.self, forKey: .repositoryFullName),
      repositoryURL: try container.decode(URL.self, forKey: .repositoryURL),
      workspacesRoot: try container.decode(URL.self, forKey: .workspacesRoot)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case appID, installationID, repositoryID, repositoryFullName, repositoryURL, workspacesRoot
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

public struct GitHubIssueRecord: Codable, Equatable, Sendable {
  public let number: Int32
  public let title: String?
  public let body: String?
  public let state: GitHubIssueState?
  public let htmlURL: URL?
  public let authorLogin: String?
  public let labels: [String]
  public let assigneeLogins: [String]

  public init(
    number: Int32,
    title: String? = nil,
    body: String? = nil,
    state: GitHubIssueState? = nil,
    htmlURL: URL? = nil,
    authorLogin: String? = nil,
    labels: [String] = [],
    assigneeLogins: [String] = []
  ) {
    self.number = number
    self.title = title
    self.body = body
    self.state = state
    self.htmlURL = htmlURL
    self.authorLogin = authorLogin
    self.labels = labels
    self.assigneeLogins = assigneeLogins
  }

  public init(from decoder: any Decoder) throws {
    try StrictProtocolCoding.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let number = try container.decode(Int32.self, forKey: .number)
    guard number > 0 else { throw GitHubCapabilityProtocolError.invalidPayload }
    self.init(
      number: number,
      title: try container.decodeIfPresent(String.self, forKey: .title),
      body: try container.decodeIfPresent(String.self, forKey: .body),
      state: try container.decodeIfPresent(GitHubIssueState.self, forKey: .state),
      htmlURL: try container.decodeIfPresent(URL.self, forKey: .htmlURL),
      authorLogin: try container.decodeIfPresent(String.self, forKey: .authorLogin),
      labels: try container.decodeIfPresent([String].self, forKey: .labels) ?? [],
      assigneeLogins: try container.decodeIfPresent([String].self, forKey: .assigneeLogins) ?? []
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case number, title, body, state, htmlURL, authorLogin, labels, assigneeLogins
  }
}

public struct GitHubIssueCommentRecord: Codable, Equatable, Sendable {
  public let id: Int64
  public let body: String?
  public let htmlURL: URL?
  public let authorLogin: String?
  public let createdAt: String?
  public let updatedAt: String?

  public init(
    id: Int64,
    body: String? = nil,
    htmlURL: URL? = nil,
    authorLogin: String? = nil,
    createdAt: String? = nil,
    updatedAt: String? = nil
  ) {
    self.id = id
    self.body = body
    self.htmlURL = htmlURL
    self.authorLogin = authorLogin
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public init(from decoder: any Decoder) throws {
    try StrictProtocolCoding.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(Int64.self, forKey: .id)
    guard id > 0 else { throw GitHubCapabilityProtocolError.invalidPayload }
    self.init(
      id: id,
      body: try container.decodeIfPresent(String.self, forKey: .body),
      htmlURL: try container.decodeIfPresent(URL.self, forKey: .htmlURL),
      authorLogin: try container.decodeIfPresent(String.self, forKey: .authorLogin),
      createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt),
      updatedAt: try container.decodeIfPresent(String.self, forKey: .updatedAt)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, body, htmlURL, authorLogin, createdAt, updatedAt
  }
}

public enum GitHubIssueCapabilityResponse: Codable, Equatable, Sendable {
  case issueList([GitHubIssueRecord])
  case issue(GitHubIssueRecord)
  case comments([GitHubIssueCommentRecord])
  case comment(GitHubIssueCommentRecord)
  case stateChanged(GitHubIssueRecord)

  private enum Kind: String, Codable { case issueList, issue, comments, comment, stateChanged }
  private enum CodingKeys: String, CodingKey, CaseIterable { case kind, issues, issue, comments, comment }

  public init(from decoder: any Decoder) throws {
    try StrictProtocolCoding.rejectUnknownKeys(
      in: decoder,
      allowed: CodingKeys.allCases.map(\.stringValue)
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .issueList:
      guard Set(container.allKeys) == [.kind, .issues] else { throw GitHubCapabilityProtocolError.invalidPayload }
      self = .issueList(try container.decode([GitHubIssueRecord].self, forKey: .issues))
    case .issue:
      guard Set(container.allKeys) == [.kind, .issue] else { throw GitHubCapabilityProtocolError.invalidPayload }
      self = .issue(try container.decode(GitHubIssueRecord.self, forKey: .issue))
    case .comments:
      guard Set(container.allKeys) == [.kind, .comments] else { throw GitHubCapabilityProtocolError.invalidPayload }
      self = .comments(try container.decode([GitHubIssueCommentRecord].self, forKey: .comments))
    case .comment:
      guard Set(container.allKeys) == [.kind, .comment] else { throw GitHubCapabilityProtocolError.invalidPayload }
      self = .comment(try container.decode(GitHubIssueCommentRecord.self, forKey: .comment))
    case .stateChanged:
      guard Set(container.allKeys) == [.kind, .issue] else { throw GitHubCapabilityProtocolError.invalidPayload }
      self = .stateChanged(try container.decode(GitHubIssueRecord.self, forKey: .issue))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .issueList(let issues):
      try container.encode(Kind.issueList, forKey: .kind)
      try container.encode(issues, forKey: .issues)
    case .issue(let issue):
      try container.encode(Kind.issue, forKey: .kind)
      try container.encode(issue, forKey: .issue)
    case .comments(let comments):
      try container.encode(Kind.comments, forKey: .kind)
      try container.encode(comments, forKey: .comments)
    case .comment(let comment):
      try container.encode(Kind.comment, forKey: .kind)
      try container.encode(comment, forKey: .comment)
    case .stateChanged(let issue):
      try container.encode(Kind.stateChanged, forKey: .kind)
      try container.encode(issue, forKey: .issue)
    }
  }
}

public enum GitRepositoryCapabilityRequest: Codable, Equatable, Sendable {
  case clone(targetName: String)
  case fetch(repositoryName: String)
  case push(repositoryName: String, branch: String)

  private enum Operation: String, Codable { case clone, fetch, push }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case operation, targetName, repositoryName, branch
  }

  public init(from decoder: any Decoder) throws {
    try StrictProtocolCoding.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Operation.self, forKey: .operation) {
    case .clone:
      guard Set(container.allKeys) == [.operation, .targetName] else { throw GitHubCapabilityProtocolError.invalidPayload }
      self = .clone(targetName: try container.decode(String.self, forKey: .targetName))
    case .fetch:
      guard Set(container.allKeys) == [.operation, .repositoryName] else { throw GitHubCapabilityProtocolError.invalidPayload }
      self = .fetch(repositoryName: try container.decode(String.self, forKey: .repositoryName))
    case .push:
      guard Set(container.allKeys) == [.operation, .repositoryName, .branch] else { throw GitHubCapabilityProtocolError.invalidPayload }
      self = .push(
        repositoryName: try container.decode(String.self, forKey: .repositoryName),
        branch: try container.decode(String.self, forKey: .branch)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .clone(let targetName):
      try container.encode(Operation.clone, forKey: .operation)
      try container.encode(targetName, forKey: .targetName)
    case .fetch(let repositoryName):
      try container.encode(Operation.fetch, forKey: .operation)
      try container.encode(repositoryName, forKey: .repositoryName)
    case .push(let repositoryName, let branch):
      try container.encode(Operation.push, forKey: .operation)
      try container.encode(repositoryName, forKey: .repositoryName)
      try container.encode(branch, forKey: .branch)
    }
  }
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

  public init(from decoder: any Decoder) throws {
    try StrictProtocolCoding.rejectUnknownKeys(
      in: decoder,
      allowed: CodingKeys.allCases.map(\.stringValue)
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      exitStatus: try container.decode(Int32.self, forKey: .exitStatus),
      output: try container.decode(String.self, forKey: .output),
      wasTruncated: try container.decode(Bool.self, forKey: .wasTruncated)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case exitStatus, output, wasTruncated
  }
}

public struct GitHubCapabilityFailure: Codable, Equatable, Sendable {
  public enum Category: String, Codable, Sendable {
    case locked, unauthorizedScope, invalidRequest, authExpired
    case appCredentialRejected, installationRevoked, repositoryUnavailable
    case resourceNotFound, permissionDenied, rateLimited
    case networkUnavailable, timedOut, serviceUnavailable, invalidServiceResponse
    case redirectRejected, ambiguousMutationAuthenticationFailure, ambiguousMutationFailure
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

  public init(from decoder: any Decoder) throws {
    try StrictProtocolCoding.rejectUnknownKeys(
      in: decoder,
      allowed: CodingKeys.allCases.map(\.stringValue)
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      category: try container.decode(Category.self, forKey: .category),
      message: try container.decode(String.self, forKey: .message),
      status: try container.decodeIfPresent(Int.self, forKey: .status),
      retryAt: try container.decodeIfPresent(Date.self, forKey: .retryAt),
      effectMayHaveOccurred: try container.decodeIfPresent(Bool.self, forKey: .effectMayHaveOccurred)
        ?? false
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case category, message, status, retryAt, effectMayHaveOccurred
  }
}

public enum GitHubCapabilityProtocolError: LocalizedError, Equatable, Sendable {
  case invalidPage, invalidLabels, invalidAssignee, invalidSince
  case invalidIssueNumber, invalidComment, invalidPayload, unknownField

  public var errorDescription: String? {
    "The GitHub capability request is invalid."
  }
}

struct AnyCodingKey: CodingKey {
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

enum StrictProtocolCoding {
  static func rejectUnknownKeys(in decoder: any Decoder, allowed: [String]) throws {
    let values = try decoder.container(keyedBy: AnyCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)).isSubset(of: Set(allowed)) else {
      throw GitHubCapabilityProtocolError.unknownField
    }
  }
}
