import Foundation
import SymphonyCredentialBrokerProtocol

public protocol GitHubHTTPTransporting: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionGitHubHTTPTransport: GitHubHTTPTransporting {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw GitHubAppAPIError.invalidResponse
    }
    return (data, response)
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

  public init(
    baseURL: URL = URL(string: "https://api.github.com")!,
    transport: any GitHubHTTPTransporting = URLSessionGitHubHTTPTransport()
  ) {
    self.baseURL = baseURL
    self.transport = transport
  }

  public func listInstallations(jwt: String) async throws -> [GitHubInstallationDescriptor] {
    var all: [GitHubInstallationDescriptor] = []
    for page in 1...10 {
      let request = try makeRequest(
        path: "/app/installations",
        bearer: jwt,
        queryItems: pageQuery(page)
      )
      let data = try await send(request, authentication: .app)
      let pageValues = try decode([InstallationResponse].self, from: data)
      all.append(contentsOf: pageValues.map(\.descriptor))
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
    var tokenRequest = try makeRequest(
      path: "/app/installations/\(installationID)/access_tokens",
      bearer: jwt
    )
    tokenRequest.httpMethod = "POST"
    tokenRequest.httpBody = Data("{}".utf8)
    let tokenData = try await send(tokenRequest, authentication: .installation(installationID))
    let token = try decode(InstallationTokenResponse.self, from: tokenData).token

    var all: [GitHubRepositoryDescriptor] = []
    for page in 1...10 {
      let request = try makeRequest(
        path: "/installation/repositories",
        bearer: token,
        queryItems: pageQuery(page)
      )
      let data = try await send(request, authentication: .installation(installationID))
      let response = try decode(RepositoriesResponse.self, from: data)
      all.append(contentsOf: response.repositories.map(\.descriptor))
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
    queryItems: [URLQueryItem] = []
  ) throws -> URLRequest {
    guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
      throw GitHubAppAPIError.invalidResponse
    }
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else {
      throw GitHubAppAPIError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("SymphonyDesktop", forHTTPHeaderField: "User-Agent")
    return request
  }

  private func send(_ request: URLRequest, authentication: Authentication) async throws -> Data {
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.data(for: request)
    } catch let error as GitHubAppAPIError {
      throw error
    } catch {
      throw GitHubAppAPIError.transport(error.localizedDescription)
    }
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
    }
  }
}
