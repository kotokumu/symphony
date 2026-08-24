import Darwin
import Foundation
import SymphonyCredentialBrokerProtocol

struct FileIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
}

struct AuthorizedGitHubRepositoryScope: Equatable, Sendable {
  let appID: Int64
  let installationID: Int64
  let repositoryID: Int64
  let owner: String
  let repository: String
  let repositoryURL: URL
  let workspacesRoot: URL
  let workspacesRootIdentity: FileIdentity

  init(_ authorization: GitHubRepositoryAuthorization, storedAppID: Int64) throws {
    guard authorization.appID == storedAppID,
      authorization.appID > 0,
      authorization.installationID > 0,
      authorization.repositoryID > 0
    else {
      throw GitHubRepositoryAccessError.unauthorizedScope
    }
    let name = try GitHubRepositoryIdentity(fullName: authorization.repositoryFullName)
    guard name.matches(authorization.repositoryURL) else {
      throw GitHubRepositoryAccessError.unauthorizedScope
    }
    let requestedRoot = authorization.workspacesRoot.standardizedFileURL
    guard requestedRoot.isFileURL, requestedRoot.path.hasPrefix("/"), requestedRoot.path != "/" else {
      throw GitHubRepositoryAccessError.invalidWorkspaceRoot
    }
    var information = stat()
    guard lstat(requestedRoot.path, &information) == 0,
      information.st_mode & S_IFMT == S_IFDIR
    else {
      throw GitHubRepositoryAccessError.invalidWorkspaceRoot
    }
    let root = requestedRoot.resolvingSymlinksInPath()
    guard lstat(root.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR else {
      throw GitHubRepositoryAccessError.invalidWorkspaceRoot
    }

    appID = authorization.appID
    installationID = authorization.installationID
    repositoryID = authorization.repositoryID
    owner = name.owner
    repository = name.repository
    repositoryURL = URL(string: "https://github.com/\(name.owner)/\(name.repository)")!
    workspacesRoot = root
    workspacesRootIdentity = FileIdentity(
      device: UInt64(information.st_dev),
      inode: UInt64(information.st_ino)
    )
  }
}

struct GitHubRepositoryIdentity: Equatable, Sendable {
  let owner: String
  let repository: String

  init(owner: String, repository: String) {
    self.owner = owner
    self.repository = repository
  }

  init(fullName: String) throws {
    let components = fullName.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2 else { throw GitHubRepositoryAccessError.unauthorizedScope }
    owner = String(components[0])
    repository = String(components[1])
    guard Self.isValidComponent(owner), Self.isValidComponent(repository) else {
      throw GitHubRepositoryAccessError.unauthorizedScope
    }
  }

  func matches(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    guard url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "github.com",
      url.user == nil,
      url.password == nil,
      url.port == nil,
      url.query == nil,
      url.fragment == nil,
      components.percentEncodedPath == url.path
    else {
      return false
    }
    var path = url.path
    if path.hasSuffix("/") { path.removeLast() }
    let values = path.split(separator: "/", omittingEmptySubsequences: false)
    guard values.count == 3, values[0].isEmpty else { return false }
    let urlOwner = String(values[1])
    var urlRepository = String(values[2])
    if urlRepository.lowercased().hasSuffix(".git") {
      urlRepository.removeLast(4)
    }
    guard Self.isValidComponent(urlOwner), Self.isValidComponent(urlRepository) else {
      return false
    }
    return owner.lowercased() == urlOwner.lowercased()
      && repository.lowercased() == urlRepository.lowercased()
  }

  private static func isValidComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 100
      && value.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
          || (0x61...0x7A).contains($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
      }
  }
}

public enum GitHubRepositoryAccessError: LocalizedError, Sendable {
  case locked
  case unauthorizedScope
  case conflictingScope
  case invalidWorkspaceRoot
  case invalidRequest

  public var failure: GitHubCapabilityFailure {
    let category: GitHubCapabilityFailure.Category
    let message: String
    switch self {
    case .locked:
      category = .locked
      message = "Protected GitHub access is locked."
    case .unauthorizedScope, .conflictingScope:
      category = .unauthorizedScope
      message = "The GitHub request does not match this namespace's selected repository."
    case .invalidWorkspaceRoot:
      category = .unauthorizedScope
      message = "The namespace workspace root is not safe to use."
    case .invalidRequest:
      category = .invalidRequest
      message = "The GitHub capability request is invalid."
    }
    return GitHubCapabilityFailure(category: category, message: message)
  }

  public var errorDescription: String? { failure.message }
}
