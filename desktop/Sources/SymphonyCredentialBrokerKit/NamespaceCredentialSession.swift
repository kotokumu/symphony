import Foundation
import Security

public actor NamespaceCredentialSession {
  public typealias CredentialGenerator = @Sendable () throws -> Data

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
      var material: Data
      if let stored = try storage.load(namespaceID: namespaceID, authorization: authorization) {
        material = stored
      } else {
        material = try credentialGenerator()
        try storage.store(material, namespaceID: namespaceID, authorization: authorization)
      }
      credential = SecureSecretBuffer(copying: material)
      material.resetBytes(in: material.startIndex..<material.endIndex)
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

  var retainedByteCount: Int {
    credential?.retainedByteCount ?? 0
  }

  public static func randomCredential() throws -> Data {
    var data = Data(count: 32)
    let status = data.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw NamespaceCredentialStorageError.keychain(status)
    }
    return data
  }
}
