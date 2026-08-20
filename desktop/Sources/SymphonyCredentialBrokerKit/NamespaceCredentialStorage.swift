import Foundation
import LocalAuthentication
import Security

public protocol NamespaceCredentialStoring: Sendable {
  func load(
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws -> Data?
  func store(
    _ credential: Data,
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws
  func replace(
    _ credential: Data,
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws
  func removeAll(namespaceID: UUID) throws
}

public protocol NamespaceKeychainAccessing: Sendable {
  func makeAccessControl(
    accessibility: CFTypeRef,
    flags: SecAccessControlCreateFlags
  ) throws -> SecAccessControl
  func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?)
  func add(_ attributes: CFDictionary) -> OSStatus
  func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
  func delete(_ query: CFDictionary) -> OSStatus
}

public struct SystemNamespaceKeychainClient: NamespaceKeychainAccessing {
  public init() {}

  public func makeAccessControl(
    accessibility: CFTypeRef,
    flags: SecAccessControlCreateFlags
  ) throws -> SecAccessControl {
    var error: Unmanaged<CFError>?
    guard
      let accessControl = SecAccessControlCreateWithFlags(
        nil,
        accessibility,
        flags,
        &error
      )
    else {
      throw NamespaceCredentialStorageError.accessControl(
        error?.takeRetainedValue().localizedDescription
          ?? "The access-control policy could not be created."
      )
    }
    return accessControl
  }

  public func copyMatching(
    _ query: CFDictionary
  ) -> (status: OSStatus, result: CFTypeRef?) {
    var result: CFTypeRef?
    return (SecItemCopyMatching(query, &result), result)
  }

  public func add(_ attributes: CFDictionary) -> OSStatus {
    SecItemAdd(attributes, nil)
  }

  public func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
    SecItemUpdate(query, attributes)
  }

  public func delete(_ query: CFDictionary) -> OSStatus {
    SecItemDelete(query)
  }
}

public struct KeychainNamespaceCredentialStorage: NamespaceCredentialStoring {
  private static let service = "com.openai.symphony.namespace-credential"
  private let keychain: any NamespaceKeychainAccessing

  public init(keychain: any NamespaceKeychainAccessing = SystemNamespaceKeychainClient()) {
    self.keychain = keychain
  }

  public func load(
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws -> Data? {
    var query = baseQuery(namespaceID: namespaceID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = authorization.context

    let (status, result) = keychain.copyMatching(query as CFDictionary)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else {
        throw NamespaceCredentialStorageError.invalidStoredValue
      }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw NamespaceCredentialStorageError.keychain(status)
    }
  }

  public func store(
    _ credential: Data,
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws {
    let accessControl = try keychain.makeAccessControl(
      accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      flags: .userPresence
    )

    var query = baseQuery(namespaceID: namespaceID)
    query[kSecValueData as String] = credential
    query[kSecAttrAccessControl as String] = accessControl
    query[kSecUseAuthenticationContext as String] = authorization.context

    let status = keychain.add(query as CFDictionary)
    guard status == errSecSuccess else {
      throw NamespaceCredentialStorageError.keychain(status)
    }
  }

  public func removeAll(namespaceID: UUID) throws {
    let status = keychain.delete(baseQuery(namespaceID: namespaceID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NamespaceCredentialStorageError.keychain(status)
    }
  }

  public func replace(
    _ credential: Data,
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws {
    var query = baseQuery(namespaceID: namespaceID)
    query[kSecUseAuthenticationContext as String] = authorization.context
    let attributes = [kSecValueData as String: credential]
    let status = keychain.update(query as CFDictionary, attributes: attributes as CFDictionary)
    guard status == errSecSuccess else {
      throw NamespaceCredentialStorageError.keychain(status)
    }
  }

  private func baseQuery(namespaceID: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: namespaceID.uuidString.lowercased(),
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
    ]
  }
}

public enum NamespaceCredentialStorageError: LocalizedError, Sendable {
  case accessControl(String)
  case invalidStoredValue
  case keychain(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .accessControl(let message):
      return "Protected credential storage is unavailable: \(message)"
    case .invalidStoredValue:
      return "The protected namespace credential is unreadable."
    case .keychain(let status):
      let message = SecCopyErrorMessageString(status, nil) as String?
      return "Protected credential storage failed: \(message ?? "Keychain error \(status)")"
    }
  }
}
