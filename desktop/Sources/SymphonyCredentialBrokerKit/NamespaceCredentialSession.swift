import Foundation
import CryptoKit
import Security
import SymphonyCredentialBrokerProtocol

public actor NamespaceCredentialSession {
  public typealias CredentialGenerator = @Sendable () throws -> SecureSecretBuffer

  private let namespaceID: UUID
  private let authorizer: any NamespaceUnlockAuthorizing
  private let storage: any NamespaceCredentialStoring
  private let credentialGenerator: CredentialGenerator
  private let githubAPI: any GitHubAppAPIRequesting
  private var authorization: NamespaceUnlockAuthorization?
  private var credential: SecureSecretBuffer?

  public init(
    namespaceID: UUID,
    authorizer: any NamespaceUnlockAuthorizing = LocalAuthenticationNamespaceUnlockAuthorizer(),
    storage: any NamespaceCredentialStoring = KeychainNamespaceCredentialStorage(),
    credentialGenerator: @escaping CredentialGenerator = NamespaceCredentialSession.randomCredential,
    githubAPI: any GitHubAppAPIRequesting = GitHubAppAPIClient()
  ) {
    self.namespaceID = namespaceID
    self.authorizer = authorizer
    self.storage = storage
    self.credentialGenerator = credentialGenerator
    self.githubAPI = githubAPI
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

  public func lock() {
    credential?.clear()
    credential = nil
    authorization?.invalidate()
    authorization = nil
  }

  public func removeStoredCredential() throws {
    lock()
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

  public func configureGitHubApp(appID: Int64, privateKeyFilePath: String) throws {
    guard let authorization, credential != nil else {
      throw NamespaceCredentialSessionError.locked
    }
    let fileURL = URL(fileURLWithPath: privateKeyFilePath)
    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
    guard values?.isRegularFile == true else {
      throw GitHubAppCredentialError.invalidPrivateKey
    }

    var pemData = try Data(contentsOf: fileURL)
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

  var retainedByteCount: Int {
    credential?.retainedByteCount ?? 0
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
}

public enum NamespaceCredentialSessionError: LocalizedError, Sendable {
  case locked

  public var errorDescription: String? {
    "Protected namespace credentials are locked."
  }
}
