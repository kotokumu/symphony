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
  private let api: any GitHubRepositoryAPIRequesting
  private let now: @Sendable () -> Date
  private let git: any ScopedGitRunning
  private var scope: AuthorizedGitHubRepositoryScope?
  private var lease: InstallationTokenLease?
  private var generation = UUID()

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
    jwt: String?
  ) async throws -> GitHubIssueCapabilityResponse {
    guard let scope else { throw GitHubRepositoryAccessError.locked }
    let operationGeneration = generation
    let token = try await installationToken(
      scope: scope,
      jwt: jwt,
      generation: operationGeneration
    )
    do {
      let response = try await api.performIssueRequest(request, scope: scope, token: token)
      try requireCurrent(operationGeneration, scope: scope)
      return GitHubIssueCapabilityResponse(
        status: response.status,
        body: token.redacting(response.body)
      )
    } catch let error as GitHubRepositoryAPIError {
      if error.invalidatesLease { clearLease() }
      if error.shouldRetryGET, request.isReadOperation {
        guard let jwt else { throw error }
        let replacement = try await refreshToken(
          scope: scope,
          jwt: jwt,
          generation: operationGeneration
        )
        do {
          let response = try await api.performIssueRequest(request, scope: scope, token: replacement)
          try requireCurrent(operationGeneration, scope: scope)
          return GitHubIssueCapabilityResponse(
            status: response.status,
            body: replacement.redacting(response.body)
          )
        } catch let retryError as GitHubRepositoryAPIError {
          if retryError.invalidatesLease { clearLease() }
          throw retryError.afterRetry
        }
      }
      throw error.forRequest(request)
    }
  }

  func clear() {
    generation = UUID()
    clearLease()
    scope = nil
  }

  func performGitOperation(
    _ request: GitRepositoryCapabilityRequest,
    jwt: String
  ) async throws -> GitRepositoryCapabilityResult {
    guard let scope else { throw GitHubRepositoryAccessError.locked }
    let operationGeneration = generation
    do {
      return try await git.run(request, in: scope) {
        try await self.operationCredential(
          scope: scope,
          jwt: jwt,
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

  func stopRetainedGitOperation() async throws {
    try await git.stopRetainedOperation()
  }

  var hasAuthorizedScope: Bool { scope != nil }
  var retainedTokenByteCount: Int { lease?.token.retainedByteCount ?? 0 }
  var needsJWT: Bool { lease?.isUsable(at: now()) != true }

  private func installationToken(
    scope: AuthorizedGitHubRepositoryScope,
    jwt: String?,
    generation: UUID
  ) async throws -> SecureSecretBuffer {
    try requireCurrent(generation, scope: scope)
    if let lease, lease.isUsable(at: now()) { return lease.token }
    guard let jwt else { throw GitHubRepositoryAccessError.locked }
    return try await refreshToken(scope: scope, jwt: jwt, generation: generation)
  }

  private func refreshToken(
    scope: AuthorizedGitHubRepositoryScope,
    jwt: String,
    generation: UUID
  ) async throws -> SecureSecretBuffer {
    clearLease()
    let minted = try await api.mintInstallationToken(scope: scope, jwt: jwt)
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
    jwt: String,
    generation: UUID
  ) async throws -> OperationCredential {
    let token = try await installationToken(scope: scope, jwt: jwt, generation: generation)
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
            category: .appCredentialRejected,
            message: "GitHub rejected refreshed App authentication. Reconnect this namespace.",
            status: failure.status
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
      guard failure.category == .authExpired, !request.isReadOperation else { return self }
      return .failure(
        GitHubCapabilityFailure(
          category: .ambiguousMutationAuthenticationFailure,
          message: "GitHub authentication failed after the mutation was dispatched. Inspect the issue before retrying.",
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
}
