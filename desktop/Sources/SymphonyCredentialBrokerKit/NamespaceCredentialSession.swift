import Foundation
import CryptoKit
import Security

public actor NamespaceCredentialSession {
  public typealias CredentialGenerator = @Sendable () throws -> SecureSecretBuffer

  private let namespaceID: UUID
  private let authorizer: any NamespaceUnlockAuthorizing
  private let storage: any NamespaceCredentialStoring
  private let credentialGenerator: CredentialGenerator
  private var authorization: NamespaceUnlockAuthorization?
  private var credential: SecureSecretBuffer?

  public init(
    namespaceID: UUID,
    authorizer: any NamespaceUnlockAuthorizing = LocalAuthenticationNamespaceUnlockAuthorizer(),
    storage: any NamespaceCredentialStoring = KeychainNamespaceCredentialStorage(),
    credentialGenerator: @escaping CredentialGenerator = NamespaceCredentialSession.randomCredential
  ) {
    self.namespaceID = namespaceID
    self.authorizer = authorizer
    self.storage = storage
    self.credentialGenerator = credentialGenerator
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
}

public enum NamespaceCredentialSessionError: LocalizedError, Sendable {
  case locked

  public var errorDescription: String? {
    "Protected namespace credentials are locked."
  }
}
