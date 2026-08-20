import Foundation
import CryptoKit
import Darwin
import Security
import SymphonyCredentialBrokerProtocol

public actor NamespaceCredentialSession {
  public typealias CredentialGenerator = @Sendable () throws -> SecureSecretBuffer

  private let namespaceID: UUID
  private let authorizer: any NamespaceUnlockAuthorizing
  private let storage: any NamespaceCredentialStoring
  private let credentialGenerator: CredentialGenerator
  private let githubAPI: any GitHubAppAPIRequesting
  private let githubAccess: NamespaceGitHubAccessSession
  private var authorization: NamespaceUnlockAuthorization?
  private var credential: SecureSecretBuffer?

  public init(
    namespaceID: UUID,
    authorizer: any NamespaceUnlockAuthorizing = LocalAuthenticationNamespaceUnlockAuthorizer(),
    storage: any NamespaceCredentialStoring = KeychainNamespaceCredentialStorage(),
    credentialGenerator: @escaping CredentialGenerator = NamespaceCredentialSession.randomCredential,
    githubService: GitHubAppAPIClient = GitHubAppAPIClient()
  ) {
    self.namespaceID = namespaceID
    self.authorizer = authorizer
    self.storage = storage
    self.credentialGenerator = credentialGenerator
    githubAPI = githubService
    githubAccess = NamespaceGitHubAccessSession(api: githubService)
  }

  init(
    namespaceID: UUID,
    authorizer: any NamespaceUnlockAuthorizing,
    storage: any NamespaceCredentialStoring,
    credentialGenerator: @escaping CredentialGenerator,
    githubAPI: any GitHubAppAPIRequesting,
    githubRepositoryAPI: any GitHubRepositoryAPIRequesting,
    now: @escaping @Sendable () -> Date
  ) {
    self.namespaceID = namespaceID
    self.authorizer = authorizer
    self.storage = storage
    self.credentialGenerator = credentialGenerator
    self.githubAPI = githubAPI
    githubAccess = NamespaceGitHubAccessSession(api: githubRepositoryAPI, now: now)
  }

  deinit {
    credential?.clear()
    authorization?.invalidate()
  }

  public func unlock(reason: String) async throws {
    guard credential == nil else {
      return
    }

    let authorization = try await authorizer.authorize(reason: reason)
    do {
      if var stored = try storage.load(
        namespaceID: namespaceID,
        authorization: authorization
      ) {
        defer { stored.resetBytes(in: stored.startIndex..<stored.endIndex) }
        credential = SecureSecretBuffer(copying: stored)
      } else {
        let generated = try credentialGenerator()
        do {
          try generated.withTemporaryData { material in
            try storage.store(
              material,
              namespaceID: namespaceID,
              authorization: authorization
            )
          }
          credential = generated
        } catch {
          generated.clear()
          throw error
        }
      }
      self.authorization = authorization
    } catch {
      authorization.invalidate()
      throw error
    }
  }

  public func lock() async throws {
    try await githubAccess.quiesceAndClear()
    credential?.clear()
    credential = nil
    authorization?.invalidate()
    authorization = nil
  }

  public func removeStoredCredential() async throws {
    try await lock()
    try storage.removeAll(namespaceID: namespaceID)
  }

  public func signChallenge(_ challenge: Data) throws -> Data {
    guard let credential else {
      throw NamespaceCredentialSessionError.locked
    }
    return credential.withUnsafeBytes { credentialBytes in
      let key = SymmetricKey(data: credentialBytes)
      let authenticationCode = HMAC<SHA256>.authenticationCode(
        for: challenge,
        using: key
      )
      return Data(authenticationCode)
    }
  }

  public func configureGitHubApp(appID: Int64, privateKeyFilePath: String) async throws {
    guard let authorization, credential != nil else {
      throw NamespaceCredentialSessionError.locked
    }
    try await githubAccess.quiesceAndClear()
    var pemData = try Self.readPrivateKey(at: privateKeyFilePath)
    defer { pemData.resetBytes(in: pemData.startIndex..<pemData.endIndex) }
    var githubCredential = try StoredGitHubAppCredential(appID: appID, pemData: pemData)
    defer { githubCredential.clear() }
    var encoded = try githubCredential.encodeForStorage()
    defer { encoded.resetBytes(in: encoded.startIndex..<encoded.endIndex) }
    let replacement = SecureSecretBuffer(copying: encoded)

    do {
      try storage.replace(
        encoded,
        namespaceID: namespaceID,
        authorization: authorization
      )
    } catch {
      replacement.clear()
      throw error
    }
    credential?.clear()
    credential = replacement
  }

  public func listGitHubInstallations() async throws -> [GitHubInstallationDescriptor] {
    let jwt = try githubJWT()
    return try await githubAPI.listInstallations(jwt: jwt)
  }

  public func listGitHubRepositories(
    installationID: Int64
  ) async throws -> [GitHubRepositoryDescriptor] {
    let jwt = try githubJWT()
    return try await githubAPI.listRepositories(installationID: installationID, jwt: jwt)
  }

  public func authorizeGitHubRepository(
    _ authorization: GitHubRepositoryAuthorization
  ) async throws {
    let repositories = try await githubAPI.listRepositories(
      installationID: authorization.installationID,
      jwt: githubJWT()
    )
    guard repositories.contains(where: {
      $0.id == authorization.repositoryID
        && $0.fullName.caseInsensitiveCompare(authorization.repositoryFullName) == .orderedSame
        && $0.htmlURL == authorization.repositoryURL
    }) else {
      throw GitHubRepositoryAccessError.unauthorizedScope
    }
    try await githubAccess.authorize(authorization, storedAppID: try githubCredentialAppID())
  }

  public func performGitHubIssueRequest(
    _ request: GitHubIssueCapabilityRequest
  ) async throws -> GitHubIssueCapabilityResponse {
    try await githubAccess.performIssueRequest(request) { [weak self] in
      guard let self else { throw NamespaceCredentialSessionError.locked }
      return try await self.githubJWT()
    }
  }

  public func performGitHubGitOperation(
    _ request: GitRepositoryCapabilityRequest
  ) async throws -> GitRepositoryCapabilityResult {
    try await githubAccess.performGitOperation(request) { [weak self] in
      guard let self else { throw NamespaceCredentialSessionError.locked }
      return try await self.githubJWT()
    }
  }

  var retainedByteCount: Int {
    credential?.retainedByteCount ?? 0
  }

  var retainedInstallationTokenByteCount: Int {
    get async { await githubAccess.retainedTokenByteCount }
  }

  public static func randomCredential() throws -> SecureSecretBuffer {
    var data = Data(count: 32)
    defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
    let status = data.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw NamespaceCredentialStorageError.keychain(status)
    }
    return SecureSecretBuffer(copying: data)
  }

  private func githubJWT() throws -> String {
    guard let credential else {
      throw NamespaceCredentialSessionError.locked
    }
    return try credential.withTemporaryData { data in
      var githubCredential = try StoredGitHubAppCredential.decode(from: data)
      defer { githubCredential.clear() }
      return try githubCredential.makeJWT()
    }
  }

  private func githubCredentialAppID() throws -> Int64 {
    guard let credential else { throw NamespaceCredentialSessionError.locked }
    return try credential.withTemporaryData { data in
      var githubCredential = try StoredGitHubAppCredential.decode(from: data)
      defer { githubCredential.clear() }
      return githubCredential.appID
    }
  }

  private static func readPrivateKey(at path: String) throws -> Data {
    let maximumBytes = 128 * 1_024
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    } catch {
      throw GitHubAppCredentialError.invalidPrivateKey
    }
    defer { try? handle.close() }

    var information = stat()
    guard fstat(handle.fileDescriptor, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG
    else {
      throw GitHubAppCredentialError.invalidPrivateKey
    }
    guard information.st_size <= maximumBytes else {
      throw GitHubAppCredentialError.privateKeyTooLarge
    }
    guard var data = try handle.read(upToCount: maximumBytes + 1) else {
      throw GitHubAppCredentialError.invalidPrivateKey
    }
    guard data.count <= maximumBytes else {
      data.resetBytes(in: data.startIndex..<data.endIndex)
      throw GitHubAppCredentialError.privateKeyTooLarge
    }
    return data
  }
}

public enum NamespaceCredentialSessionError: LocalizedError, Sendable {
  case locked

  public var errorDescription: String? {
    "Protected namespace credentials are locked."
  }
}
