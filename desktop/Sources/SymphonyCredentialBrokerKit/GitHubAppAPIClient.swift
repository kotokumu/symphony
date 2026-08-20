import Foundation
import SymphonyCredentialBrokerProtocol

public protocol GitHubHTTPTransporting: Sendable {
  /// Must stop reading and return no later than `deadline`.
  func data(
    for request: URLRequest,
    maximumBytes: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionGitHubHTTPTransport: GitHubHTTPTransporting {
  private let configuration: URLSessionConfiguration

  public init(configuration: URLSessionConfiguration = makeEphemeralConfiguration()) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
  }

  public init(session: URLSession) {
    configuration = session.configuration.copy() as! URLSessionConfiguration
  }

  public static func makeEphemeralConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    return configuration
  }

  public static func makeEphemeralSession() -> URLSession {
    URLSession(configuration: makeEphemeralConfiguration())
  }

  public func data(
    for request: URLRequest,
    maximumBytes: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> (Data, HTTPURLResponse) {
    guard maximumBytes >= 0 else { throw GitHubAppAPIError.responseTooLarge }
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { throw GitHubAppAPIError.requestTimedOut }
    let reader = BoundedURLSessionReader(
      configuration: configuration,
      maximumBytes: maximumBytes,
      deadline: deadline
    )
    return try await withTaskCancellationHandler {
      try await reader.read(request)
    } onCancel: {
      reader.cancel(with: CancellationError())
    }
  }
}

private final class BoundedURLSessionReader: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  typealias Output = (Data, HTTPURLResponse)

  private let lock = NSLock()
  private let configuration: URLSessionConfiguration
  private let maximumBytes: Int
  private let deadline: ContinuousClock.Instant
  private var continuation: CheckedContinuation<Output, any Error>?
  private var session: URLSession?
  private var dataTask: URLSessionDataTask?
  private var deadlineTask: Task<Void, Never>?
  private var pendingCancellation: (any Error)?
  private var response: HTTPURLResponse?
  private var data = Data()

  init(
    configuration: URLSessionConfiguration,
    maximumBytes: Int,
    deadline: ContinuousClock.Instant
  ) {
    self.configuration = configuration
    self.maximumBytes = maximumBytes
    self.deadline = deadline
    data.reserveCapacity(min(maximumBytes, 64 * 1_024))
  }

  func read(_ request: URLRequest) async throws -> Output {
    try await withCheckedThrowingContinuation { continuation in
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      let dataTask = session.dataTask(with: request)
      let cancellation = lock.withLock { () -> (any Error)? in
        if let pendingCancellation {
          self.pendingCancellation = nil
          return pendingCancellation
        }
        self.continuation = continuation
        self.session = session
        self.dataTask = dataTask
        return nil
      }
      if let cancellation {
        session.invalidateAndCancel()
        continuation.resume(throwing: cancellation)
        return
      }
      let deadlineTask = Task { [weak self, deadline] in
        do {
          try await ContinuousClock().sleep(until: deadline)
          self?.cancel(with: GitHubAppAPIError.requestTimedOut)
        } catch {}
      }
      let shouldCancelDeadline = lock.withLock { () -> Bool in
        guard self.continuation != nil else { return true }
        self.deadlineTask = deadlineTask
        return false
      }
      if shouldCancelDeadline { deadlineTask.cancel() }
      dataTask.resume()
    }
  }

  func cancel(with error: any Error) {
    let hasContinuation = lock.withLock { () -> Bool in
      guard continuation != nil else {
        pendingCancellation = error
        return false
      }
      return true
    }
    guard hasContinuation else { return }
    finish(.failure(error), cancelling: true)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(.failure(GitHubAppAPIError.invalidResponse), cancelling: true)
      return
    }
    guard response.expectedContentLength < 0 || response.expectedContentLength <= maximumBytes else {
      completionHandler(.cancel)
      finish(.failure(GitHubAppAPIError.responseTooLarge), cancelling: true)
      return
    }
    lock.withLock { self.response = response }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    let exceeded = lock.withLock { () -> Bool in
      guard data.count <= maximumBytes,
        self.data.count <= maximumBytes - data.count
      else { return true }
      self.data.append(data)
      return false
    }
    if exceeded {
      finish(.failure(GitHubAppAPIError.responseTooLarge), cancelling: true)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      finish(.failure(error), cancelling: false)
      return
    }
    let result = lock.withLock { () -> Result<Output, any Error> in
      guard let response else {
        return .failure(GitHubAppAPIError.invalidResponse)
      }
      return .success((data, response))
    }
    finish(result, cancelling: false)
  }

  private func finish(_ result: Result<Output, any Error>, cancelling: Bool) {
    let owned = lock.withLock { () -> (
      CheckedContinuation<Output, any Error>,
      URLSessionDataTask?,
      URLSession?,
      Task<Void, Never>?
    )? in
      guard let continuation else { return nil }
      self.continuation = nil
      let owned = (continuation, dataTask, session, deadlineTask)
      dataTask = nil
      session = nil
      deadlineTask = nil
      return owned
    }
    guard let (continuation, dataTask, session, deadlineTask) = owned else { return }
    deadlineTask?.cancel()
    if cancelling {
      dataTask?.cancel()
      session?.invalidateAndCancel()
    } else {
      session?.finishTasksAndInvalidate()
    }
    continuation.resume(with: result)
  }
}

public protocol GitHubAppAPIRequesting: Sendable {
  func listInstallations(jwt: String) async throws -> [GitHubInstallationDescriptor]
  func listRepositories(
    installationID: Int64,
    jwt: String
  ) async throws -> [GitHubRepositoryDescriptor]
}

public struct GitHubAppAPIClient: GitHubAppAPIRequesting {
  private let baseURL: URL
  private let transport: any GitHubHTTPTransporting
  private let operationTimeout: Duration

  public init(
    baseURL: URL = URL(string: "https://api.github.com")!,
    transport: any GitHubHTTPTransporting = URLSessionGitHubHTTPTransport(),
    operationTimeout: Duration = CredentialBrokerProtocolLimits.defaultGitHubOperationTimeout
  ) {
    self.baseURL = baseURL
    self.transport = transport
    self.operationTimeout = operationTimeout
  }

  public func listInstallations(jwt: String) async throws -> [GitHubInstallationDescriptor] {
    let deadline = ContinuousClock.now.advanced(by: operationTimeout)
    var all: [GitHubInstallationDescriptor] = []
    for page in 1...10 {
      let request = try makeRequest(
        path: "/app/installations",
        bearer: jwt,
        queryItems: pageQuery(page),
        deadline: deadline
      )
      let data = try await send(request, authentication: .app, deadline: deadline)
      let pageValues = try decode([InstallationResponse].self, from: data)
      all.append(contentsOf: pageValues.map(\.descriptor))
      try requireDescriptorBudget(all)
      if pageValues.count < 100 { return all }
    }
    throw GitHubAppAPIError.paginationLimit
  }

  public func listRepositories(
    installationID: Int64,
    jwt: String
  ) async throws -> [GitHubRepositoryDescriptor] {
    guard installationID > 0 else {
      throw GitHubAppAPIError.installationRevoked
    }
    let deadline = ContinuousClock.now.advanced(by: operationTimeout)
    var tokenRequest = try makeRequest(
      path: "/app/installations/\(installationID)/access_tokens",
      bearer: jwt,
      deadline: deadline
    )
    tokenRequest.httpMethod = "POST"
    tokenRequest.httpBody = Data("{\"permissions\":{\"metadata\":\"read\"}}".utf8)
    let tokenData = try await send(
      tokenRequest,
      authentication: .installation(installationID),
      deadline: deadline
    )
    let token = try decode(InstallationTokenResponse.self, from: tokenData).token

    var all: [GitHubRepositoryDescriptor] = []
    for page in 1...10 {
      let request = try makeRequest(
        path: "/installation/repositories",
        bearer: token,
        queryItems: pageQuery(page),
        deadline: deadline
      )
      let data = try await send(
        request,
        authentication: .installation(installationID),
        deadline: deadline
      )
      let response = try decode(RepositoriesResponse.self, from: data)
      all.append(contentsOf: response.repositories.map(\.descriptor))
      try requireDescriptorBudget(all)
      if response.repositories.count < 100 { return all }
    }
    throw GitHubAppAPIError.paginationLimit
  }

  private func pageQuery(_ page: Int) -> [URLQueryItem] {
    [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: "\(page)")]
  }

  private func makeRequest(
    path: String,
    bearer: String,
    queryItems: [URLQueryItem] = [],
    deadline: ContinuousClock.Instant
  ) throws -> URLRequest {
    guard baseURL.scheme?.lowercased() == "https" else {
      throw GitHubAppAPIError.insecureBaseURL
    }
    guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
      throw GitHubAppAPIError.invalidResponse
    }
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else {
      throw GitHubAppAPIError.invalidResponse
    }
    var request = URLRequest(url: url)
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { throw GitHubAppAPIError.requestTimedOut }
    let durationComponents = remaining.components
    request.timeoutInterval = min(
      30,
      Double(durationComponents.seconds) + Double(durationComponents.attoseconds) / 1e18
    )
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("SymphonyDesktop", forHTTPHeaderField: "User-Agent")
    return request
  }

  private func send(
    _ request: URLRequest,
    authentication: Authentication,
    deadline: ContinuousClock.Instant
  ) async throws -> Data {
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.data(
        for: request,
        maximumBytes: 2 * 1_024 * 1_024,
        deadline: deadline
      )
    } catch let error as GitHubAppAPIError {
      throw error
    } catch {
      throw GitHubAppAPIError.transport(error.localizedDescription)
    }
    guard ContinuousClock.now < deadline else { throw GitHubAppAPIError.requestTimedOut }
    guard data.count <= 2 * 1_024 * 1_024 else {
      throw GitHubAppAPIError.responseTooLarge
    }

    guard (200..<300).contains(response.statusCode) else {
      let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).message)
      switch response.statusCode {
      case 401:
        throw GitHubAppAPIError.credentialsRejected
      case 403:
        throw GitHubAppAPIError.permissionDenied(message)
      case 404:
        switch authentication {
        case .app:
          throw GitHubAppAPIError.credentialsRejected
        case .installation:
          throw GitHubAppAPIError.installationRevoked
        }
      default:
        throw GitHubAppAPIError.status(response.statusCode, message)
      }
    }
    return data
  }

  private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw GitHubAppAPIError.invalidResponse
    }
  }

  private func requireDescriptorBudget<Value: Encodable>(_ value: Value) throws {
    guard try JSONEncoder().encode(value).count <= CredentialBrokerProtocolLimits.maximumGitHubDescriptorBytes else {
      throw GitHubAppAPIError.responseTooLarge
    }
  }
}

private enum Authentication {
  case app
  case installation(Int64)
}

private struct InstallationResponse: Decodable {
  struct Account: Decodable {
    let login: String
    let type: String
  }

  let id: Int64
  let account: Account
  let permissions: [String: String]
  let suspendedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, account, permissions
    case suspendedAt = "suspended_at"
  }

  var descriptor: GitHubInstallationDescriptor {
    GitHubInstallationDescriptor(
      id: id,
      accountLogin: account.login,
      accountType: account.type,
      permissions: permissions,
      isSuspended: suspendedAt != nil
    )
  }
}

private struct InstallationTokenResponse: Decodable {
  let token: String
}

private struct RepositoriesResponse: Decodable {
  let repositories: [RepositoryResponse]
}

private struct RepositoryResponse: Decodable {
  let id: Int64
  let fullName: String
  let htmlURL: URL
  let isPrivate: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case fullName = "full_name"
    case htmlURL = "html_url"
    case isPrivate = "private"
  }

  var descriptor: GitHubRepositoryDescriptor {
    GitHubRepositoryDescriptor(
      id: id,
      fullName: fullName,
      htmlURL: htmlURL,
      isPrivate: isPrivate
    )
  }
}

private struct APIErrorResponse: Decodable {
  let message: String
}

public enum GitHubAppAPIError: LocalizedError, Sendable {
  case transport(String)
  case credentialsRejected
  case permissionDenied(String?)
  case installationRevoked
  case status(Int, String?)
  case invalidResponse
  case responseTooLarge
  case paginationLimit
  case insecureBaseURL
  case requestTimedOut

  public var errorDescription: String? {
    switch self {
    case .transport(let message):
      "GitHub could not be reached: \(message)"
    case .credentialsRejected:
      "GitHub rejected the App ID or private key. Verify the GitHub App settings and try again."
    case .permissionDenied(let message):
      "The GitHub App installation does not have the required permission. \(message ?? "Update its repository permissions and try again.")"
    case .installationRevoked:
      "The GitHub App installation is no longer accessible. Reinstall the app or disconnect this namespace."
    case .status(let status, let message):
      "GitHub returned HTTP \(status). \(message ?? "Try again later.")"
    case .invalidResponse:
      "GitHub returned an unreadable response. Try again later."
    case .responseTooLarge:
      "GitHub returned more connection data than Symphony can process safely. Narrow the installation and try again."
    case .paginationLimit:
      "GitHub returned too many results to load safely. Narrow the app installation and try again."
    case .insecureBaseURL:
      "GitHub credentials may only be sent over HTTPS."
    case .requestTimedOut:
      "GitHub did not finish the request within the credential broker deadline. Try again."
    }
  }
}
