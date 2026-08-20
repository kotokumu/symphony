import Foundation
import SymphonyCredentialBrokerProtocol

final class InstallationTokenLease: @unchecked Sendable {
  let token: SecureSecretBuffer
  let expiresAt: Date

  init(token: SecureSecretBuffer, expiresAt: Date) {
    self.token = token
    self.expiresAt = expiresAt
  }

  deinit { token.clear() }

  func isUsable(at now: Date) -> Bool {
    expiresAt.timeIntervalSince(now) > 5 * 60
  }

  func clear() { token.clear() }
}

protocol GitHubRepositoryAPIRequesting: Sendable {
  func mintInstallationToken(
    scope: AuthorizedGitHubRepositoryScope,
    jwt: String
  ) async throws -> InstallationTokenLease
  func performIssueRequest(
    _ request: GitHubIssueCapabilityRequest,
    scope: AuthorizedGitHubRepositoryScope,
    token: SecureSecretBuffer
  ) async throws -> GitHubIssueCapabilityResponse
}

actor NamespaceGitHubAccessSession {
  typealias JWTProvider = @Sendable () async throws -> String

  private struct TrackedAPIOperation: Sendable {
    let cancel: @Sendable () -> Void
    let wait: @Sendable () async -> Void
  }
  private let api: any GitHubRepositoryAPIRequesting
  private let now: @Sendable () -> Date
  private let git: any ScopedGitRunning
  private var scope: AuthorizedGitHubRepositoryScope?
  private var lease: InstallationTokenLease?
  private var generation = UUID()
  private var apiOperations: [UUID: TrackedAPIOperation] = [:]
  private var quiescing = false

  init(
    api: any GitHubRepositoryAPIRequesting,
    git: any ScopedGitRunning = ScopedGitCommandRunner(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.api = api
    self.git = git
    self.now = now
  }

  func authorize(
    _ authorization: GitHubRepositoryAuthorization,
    storedAppID: Int64
  ) throws {
    guard !quiescing else { throw GitHubRepositoryAccessError.locked }
    let candidate = try AuthorizedGitHubRepositoryScope(
      authorization,
      storedAppID: storedAppID
    )
    if let scope {
      guard scope == candidate else { throw GitHubRepositoryAccessError.conflictingScope }
      return
    }
    scope = candidate
    generation = UUID()
  }

  func performIssueRequest(
    _ request: GitHubIssueCapabilityRequest,
    jwtProvider: @escaping JWTProvider
  ) async throws -> GitHubIssueCapabilityResponse {
    guard let scope, !quiescing else { throw GitHubRepositoryAccessError.locked }
    let operationGeneration = generation
    let token = try await installationToken(
      scope: scope,
      jwtProvider: jwtProvider,
      generation: operationGeneration
    )
    do {
      let response = try await trackedAPIRequest {
        try await self.api.performIssueRequest(request, scope: scope, token: token)
      }
      try requireCurrent(operationGeneration, scope: scope)
      return response.redacting(token)
    } catch let error as GitHubRepositoryAPIError {
      if error.invalidatesLease { clearLease() }
      if error.shouldRetryGET,
        request.isReadOperation || !error.failure.effectMayHaveOccurred
      {
        let replacement = try await refreshToken(
          scope: scope,
          jwt: try await jwtProvider(),
          generation: operationGeneration
        )
        do {
          let response = try await trackedAPIRequest {
            try await self.api.performIssueRequest(request, scope: scope, token: replacement)
          }
          try requireCurrent(operationGeneration, scope: scope)
          return response.redacting(replacement)
        } catch let retryError as GitHubRepositoryAPIError {
          if retryError.invalidatesLease { clearLease() }
          throw retryError.forRequest(request).afterRetry
        }
      }
      throw error.forRequest(request)
    }
  }

  func performIssueRequest(
    _ request: GitHubIssueCapabilityRequest,
    jwt: String
  ) async throws -> GitHubIssueCapabilityResponse {
    try await performIssueRequest(request) { jwt }
  }

  private func clear() {
    generation = UUID()
    clearLease()
    scope = nil
    quiescing = false
  }

  func performGitOperation(
    _ request: GitRepositoryCapabilityRequest,
    jwtProvider: @escaping JWTProvider
  ) async throws -> GitRepositoryCapabilityResult {
    guard let scope, !quiescing else { throw GitHubRepositoryAccessError.locked }
    let operationGeneration = generation
    do {
      return try await git.run(request, in: scope) {
        try await self.operationCredential(
          scope: scope,
          jwtProvider: jwtProvider,
          generation: operationGeneration
        )
      }
    } catch let error as GitCommandRunnerError {
      clearLease()
      throw GitHubRepositoryAPIError.failure(
        error.failure,
        invalidatesLease: true,
        retryGET: false
      )
    } catch {
      clearLease()
      throw GitHubRepositoryAPIError.failure(
        GitHubCapabilityFailure(
          category: .invalidRequest,
          message: error.localizedDescription
        ),
        invalidatesLease: true,
        retryGET: false
      )
    }
  }

  func performGitOperation(
    _ request: GitRepositoryCapabilityRequest,
    jwt: String
  ) async throws -> GitRepositoryCapabilityResult {
    try await performGitOperation(request) { jwt }
  }

  func stopRetainedGitOperation() async throws {
    try await git.stopRetainedOperation()
  }

  func quiesceAndClear() async throws {
    quiescing = true
    generation = UUID()
    let operations = Array(apiOperations.values)
    operations.forEach { $0.cancel() }
    for operation in operations { await operation.wait() }
    do {
      try await git.stopRetainedOperation()
    } catch {
      throw error
    }
    clear()
  }

  var hasAuthorizedScope: Bool { scope != nil }
  var retainedTokenByteCount: Int { lease?.token.retainedByteCount ?? 0 }
  var needsJWT: Bool { lease?.isUsable(at: now()) != true }

  private func installationToken(
    scope: AuthorizedGitHubRepositoryScope,
    jwtProvider: @escaping JWTProvider,
    generation: UUID
  ) async throws -> SecureSecretBuffer {
    try requireCurrent(generation, scope: scope)
    if let lease, lease.isUsable(at: now()) { return lease.token }
    return try await refreshToken(
      scope: scope,
      jwt: try await jwtProvider(),
      generation: generation
    )
  }

  private func refreshToken(
    scope: AuthorizedGitHubRepositoryScope,
    jwt: String,
    generation: UUID
  ) async throws -> SecureSecretBuffer {
    clearLease()
    let minted = try await trackedAPIRequest {
      try await self.api.mintInstallationToken(scope: scope, jwt: jwt)
    }
    do {
      try requireCurrent(generation, scope: scope)
    } catch {
      minted.clear()
      throw error
    }
    lease = minted
    return minted.token
  }

  private func operationCredential(
    scope: AuthorizedGitHubRepositoryScope,
    jwtProvider: @escaping JWTProvider,
    generation: UUID
  ) async throws -> OperationCredential {
    let token = try await installationToken(
      scope: scope,
      jwtProvider: jwtProvider,
      generation: generation
    )
    try requireCurrent(generation, scope: scope)
    return OperationCredential(copying: token)
  }

  private func requireCurrent(
    _ generation: UUID,
    scope: AuthorizedGitHubRepositoryScope
  ) throws {
    guard self.generation == generation, self.scope == scope else {
      throw GitHubRepositoryAccessError.locked
    }
  }

  private func clearLease() {
    lease?.clear()
    lease = nil
  }

  private func trackedAPIRequest<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    guard !quiescing else { throw GitHubRepositoryAccessError.locked }
    let id = UUID()
    let task = Task { try await operation() }
    apiOperations[id] = TrackedAPIOperation(
      cancel: { task.cancel() },
      wait: { _ = try? await task.value }
    )
    defer { apiOperations.removeValue(forKey: id) }
    return try await task.value
  }
}

private extension GitHubIssueCapabilityResponse {
  func redacting(_ token: SecureSecretBuffer) -> GitHubIssueCapabilityResponse {
    func text(_ value: String?) -> String? {
      guard let value else { return nil }
      return String(decoding: token.redacting(Data(value.utf8)), as: UTF8.self)
    }
    func issue(_ value: GitHubIssueRecord) -> GitHubIssueRecord {
      GitHubIssueRecord(
        number: value.number,
        title: text(value.title),
        body: text(value.body),
        state: value.state,
        htmlURL: value.htmlURL,
        authorLogin: text(value.authorLogin),
        labels: value.labels.compactMap { text($0) },
        assigneeLogins: value.assigneeLogins.compactMap { text($0) }
      )
    }
    func comment(_ value: GitHubIssueCommentRecord) -> GitHubIssueCommentRecord {
      GitHubIssueCommentRecord(
        id: value.id,
        body: text(value.body),
        htmlURL: value.htmlURL,
        authorLogin: text(value.authorLogin),
        createdAt: value.createdAt,
        updatedAt: value.updatedAt
      )
    }
    switch self {
    case .issueList(let values): return .issueList(values.map(issue))
    case .issue(let value): return .issue(issue(value))
    case .comments(let values): return .comments(values.map(comment))
    case .comment(let value): return .comment(comment(value))
    case .stateChanged(let value): return .stateChanged(issue(value))
    }
  }
}

private extension GitHubIssueCapabilityRequest {
  var isReadOperation: Bool {
    switch self {
    case .listIssues, .getIssue, .listComments: true
    case .createComment, .setIssueState: false
    }
  }
}

public enum GitHubRepositoryAPIError: Error, Sendable {
  case failure(GitHubCapabilityFailure, invalidatesLease: Bool, retryGET: Bool)

  var invalidatesLease: Bool {
    switch self {
    case .failure(_, let invalidatesLease, _): invalidatesLease
    }
  }

  var shouldRetryGET: Bool {
    switch self {
    case .failure(_, _, let retryGET): retryGET
    }
  }

  var afterRetry: GitHubRepositoryAPIError {
    switch self {
    case .failure(let failure, let invalidates, _):
      if failure.category == .authExpired {
        return .failure(
          GitHubCapabilityFailure(
            category: failure.effectMayHaveOccurred
              ? .ambiguousMutationAuthenticationFailure
              : .appCredentialRejected,
            message: failure.effectMayHaveOccurred
              ? "The GitHub mutation may have completed before refreshed authentication failed. Inspect the issue before retrying."
              : "GitHub rejected refreshed App authentication. Reconnect this namespace.",
            status: failure.status,
            effectMayHaveOccurred: failure.effectMayHaveOccurred
          ),
          invalidatesLease: true,
          retryGET: false
        )
      }
      return .failure(failure, invalidatesLease: invalidates, retryGET: false)
    }
  }

  func forRequest(_ request: GitHubIssueCapabilityRequest) -> GitHubRepositoryAPIError {
    switch self {
    case .failure(let failure, let invalidates, let retry):
      guard !request.isReadOperation, failure.effectMayHaveOccurred else { return self }
      let ambiguousCategories: Set<GitHubCapabilityFailure.Category> = [
        .authExpired, .networkUnavailable, .timedOut, .serviceUnavailable,
        .invalidServiceResponse,
      ]
      guard ambiguousCategories.contains(failure.category) else { return self }
      return .failure(
        GitHubCapabilityFailure(
          category: failure.category == .authExpired
            ? .ambiguousMutationAuthenticationFailure
            : .ambiguousMutationFailure,
          message: "The GitHub mutation may have completed before its result became unavailable. Inspect the issue before retrying.",
          status: failure.status,
          effectMayHaveOccurred: true
        ),
        invalidatesLease: invalidates,
        retryGET: retry
      )
    }
  }

  public var failure: GitHubCapabilityFailure {
    switch self {
    case .failure(let failure, _, _): failure
    }
  }

  static var unsupportedPullRequest: GitHubRepositoryAPIError {
    .failure(
      GitHubCapabilityFailure(
        category: .invalidRequest,
        message: "The selected number is not a GitHub issue."
      ),
      invalidatesLease: false,
      retryGET: false
    )
  }

  func markingEffectMayHaveOccurred() -> GitHubRepositoryAPIError {
    switch self {
    case .failure(let failure, let invalidatesLease, let retryGET):
      let ambiguousCategories: Set<GitHubCapabilityFailure.Category> = [
        .authExpired, .networkUnavailable, .timedOut, .serviceUnavailable,
        .invalidServiceResponse,
      ]
      guard ambiguousCategories.contains(failure.category) else { return self }
      return .failure(
        GitHubCapabilityFailure(
          category: failure.category,
          message: failure.message,
          status: failure.status,
          retryAt: failure.retryAt,
          effectMayHaveOccurred: true
        ),
        invalidatesLease: invalidatesLease,
        retryGET: retryGET
      )
    }
  }
}
