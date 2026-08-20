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
  func removeAll(namespaceID: UUID) throws
}

public struct KeychainNamespaceCredentialStorage: NamespaceCredentialStoring {
  private static let service = "com.openai.symphony.namespace-credential"

  public init() {}

  public func load(
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws -> Data? {
    var query = baseQuery(namespaceID: namespaceID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = authorization.context

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
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
    var accessControlError: Unmanaged<CFError>?
    guard
      let accessControl = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .userPresence,
        &accessControlError
      )
    else {
      throw NamespaceCredentialStorageError.accessControl(
        accessControlError?.takeRetainedValue().localizedDescription
          ?? "The access-control policy could not be created."
      )
    }

    var query = baseQuery(namespaceID: namespaceID)
    query[kSecValueData as String] = credential
    query[kSecAttrAccessControl as String] = accessControl
    query[kSecUseAuthenticationContext as String] = authorization.context

    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NamespaceCredentialStorageError.keychain(status)
    }
  }

  public func removeAll(namespaceID: UUID) throws {
    let status = SecItemDelete(baseQuery(namespaceID: namespaceID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NamespaceCredentialStorageError.keychain(status)
    }
  }

  private func baseQuery(namespaceID: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: namespaceID.uuidString.lowercased(),
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
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
