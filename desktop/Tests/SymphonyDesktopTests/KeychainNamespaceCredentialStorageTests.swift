import Foundation
import LocalAuthentication
import Security
import XCTest

@testable import SymphonyCredentialBrokerKit

final class KeychainNamespaceCredentialStorageTests: XCTestCase {
  func testLoadUsesScopedDataProtectionQueryAndAuthorizationContext() throws {
    let keychain = RecordingNamespaceKeychain(
      copyStatus: errSecSuccess,
      copyResult: Data([1, 2, 3]) as CFData
    )
    let storage = KeychainNamespaceCredentialStorage(keychain: keychain)
    let namespaceID = UUID()
    let authorization = NamespaceUnlockAuthorization(context: LAContext())

    let credential = try storage.load(
      namespaceID: namespaceID,
      authorization: authorization
    )

    XCTAssertEqual(credential, Data([1, 2, 3]))
    let query = try XCTUnwrap(keychain.copyQueries.first)
    assertBaseQuery(query, namespaceID: namespaceID)
    XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
    XCTAssertEqual(
      query[kSecMatchLimit as String] as? String,
      kSecMatchLimitOne as String
    )
    XCTAssertTrue(
      query[kSecUseAuthenticationContext as String] as? LAContext === authorization.context
    )
  }

  func testStoreRequestsThisDeviceOnlyUserPresenceAndNeverSynchronizes() throws {
    let keychain = RecordingNamespaceKeychain()
    let storage = KeychainNamespaceCredentialStorage(keychain: keychain)
    let namespaceID = UUID()
    let authorization = NamespaceUnlockAuthorization(context: LAContext())

    try storage.store(
      Data([7, 8, 9]),
      namespaceID: namespaceID,
      authorization: authorization
    )

    XCTAssertEqual(keychain.accessControlFlags, [.userPresence])
    XCTAssertEqual(keychain.accessibilityMatchesThisDeviceOnly, [true])
    let query = try XCTUnwrap(keychain.addQueries.first)
    assertBaseQuery(query, namespaceID: namespaceID)
    XCTAssertEqual(query[kSecValueData as String] as? Data, Data([7, 8, 9]))
    XCTAssertNotNil(query[kSecAttrAccessControl as String])
    XCTAssertTrue(
      query[kSecUseAuthenticationContext as String] as? LAContext === authorization.context
    )
  }

  func testMissingItemAndMissingDeleteAreIdempotent() throws {
    let keychain = RecordingNamespaceKeychain(
      copyStatus: errSecItemNotFound,
      deleteStatus: errSecItemNotFound
    )
    let storage = KeychainNamespaceCredentialStorage(keychain: keychain)
    let namespaceID = UUID()
    let authorization = NamespaceUnlockAuthorization(context: LAContext())

    XCTAssertNil(try storage.load(namespaceID: namespaceID, authorization: authorization))
    try storage.removeAll(namespaceID: namespaceID)

    let deleteQuery = try XCTUnwrap(keychain.deleteQueries.first)
    assertBaseQuery(deleteQuery, namespaceID: namespaceID)
  }

  func testReplaceUpdatesOnlyProtectedValueWithTheAuthorizationContext() throws {
    let keychain = RecordingNamespaceKeychain()
    let storage = KeychainNamespaceCredentialStorage(keychain: keychain)
    let namespaceID = UUID()
    let authorization = NamespaceUnlockAuthorization(context: LAContext())

    try storage.replace(
      Data([4, 5, 6]),
      namespaceID: namespaceID,
      authorization: authorization
    )

    let (query, attributes) = try XCTUnwrap(keychain.updateQueries.first)
    assertBaseQuery(query, namespaceID: namespaceID)
    XCTAssertTrue(
      query[kSecUseAuthenticationContext as String] as? LAContext === authorization.context
    )
    XCTAssertEqual(attributes.count, 1)
    XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data([4, 5, 6]))
  }

  func testInvalidValueAndSecurityStatusesRemainVisible() throws {
    let namespaceID = UUID()
    let authorization = NamespaceUnlockAuthorization(context: LAContext())

    let invalidValue = KeychainNamespaceCredentialStorage(
      keychain: RecordingNamespaceKeychain(copyResult: "invalid" as CFString)
    )
    XCTAssertThrowsError(
      try invalidValue.load(namespaceID: namespaceID, authorization: authorization)
    ) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "The protected namespace credential is unreadable."
      )
    }

    let loadFailure = KeychainNamespaceCredentialStorage(
      keychain: RecordingNamespaceKeychain(copyStatus: errSecAuthFailed)
    )
    XCTAssertThrowsError(
      try loadFailure.load(namespaceID: namespaceID, authorization: authorization)
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("Protected credential storage failed"))
    }

    let duplicate = KeychainNamespaceCredentialStorage(
      keychain: RecordingNamespaceKeychain(addStatus: errSecDuplicateItem)
    )
    XCTAssertThrowsError(
      try duplicate.store(
        Data([1]),
        namespaceID: namespaceID,
        authorization: authorization
      )
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("Protected credential storage failed"))
    }
  }

  func testAccessControlAndDeleteFailuresRemainVisible() throws {
    let namespaceID = UUID()
    let authorization = NamespaceUnlockAuthorization(context: LAContext())
    let accessControlFailure = KeychainNamespaceCredentialStorage(
      keychain: RecordingNamespaceKeychain(accessControlError: TestKeychainError.failed)
    )
    XCTAssertThrowsError(
      try accessControlFailure.store(
        Data([1]),
        namespaceID: namespaceID,
        authorization: authorization
      )
    ) { error in
      XCTAssertEqual(error.localizedDescription, "Access control failed.")
    }

    let deleteFailure = KeychainNamespaceCredentialStorage(
      keychain: RecordingNamespaceKeychain(deleteStatus: errSecNotAvailable)
    )
    XCTAssertThrowsError(try deleteFailure.removeAll(namespaceID: namespaceID)) { error in
      XCTAssertTrue(error.localizedDescription.contains("Protected credential storage failed"))
    }
  }

  private func assertBaseQuery(
    _ query: [String: Any],
    namespaceID: UUID,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      query[kSecClass as String] as? String,
      kSecClassGenericPassword as String,
      file: file,
      line: line
    )
    XCTAssertEqual(
      query[kSecAttrService as String] as? String,
      "com.openai.symphony.namespace-credential",
      file: file,
      line: line
    )
    XCTAssertEqual(
      query[kSecAttrAccount as String] as? String,
      namespaceID.uuidString.lowercased(),
      file: file,
      line: line
    )
    XCTAssertEqual(
      query[kSecAttrSynchronizable as String] as? Bool,
      false,
      file: file,
      line: line
    )
    XCTAssertEqual(
      query[kSecUseDataProtectionKeychain as String] as? Bool,
      true,
      file: file,
      line: line
    )
  }
}

private final class RecordingNamespaceKeychain: NamespaceKeychainAccessing, @unchecked Sendable {
  private let copyStatus: OSStatus
  private let copyResult: CFTypeRef?
  private let addStatus: OSStatus
  private let deleteStatus: OSStatus
  private let accessControlError: Error?
  private(set) var copyQueries: [[String: Any]] = []
  private(set) var addQueries: [[String: Any]] = []
  private(set) var updateQueries: [([String: Any], [String: Any])] = []
  private(set) var deleteQueries: [[String: Any]] = []
  private(set) var accessControlFlags: [SecAccessControlCreateFlags] = []
  private(set) var accessibilityMatchesThisDeviceOnly: [Bool] = []

  init(
    copyStatus: OSStatus = errSecSuccess,
    copyResult: CFTypeRef? = Data([1]) as CFData,
    addStatus: OSStatus = errSecSuccess,
    deleteStatus: OSStatus = errSecSuccess,
    accessControlError: Error? = nil
  ) {
    self.copyStatus = copyStatus
    self.copyResult = copyResult
    self.addStatus = addStatus
    self.deleteStatus = deleteStatus
    self.accessControlError = accessControlError
  }

  func makeAccessControl(
    accessibility: CFTypeRef,
    flags: SecAccessControlCreateFlags
  ) throws -> SecAccessControl {
    accessControlFlags.append(flags)
    accessibilityMatchesThisDeviceOnly.append(
      CFEqual(accessibility, kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    )
    if let accessControlError { throw accessControlError }
    return try SystemNamespaceKeychainClient().makeAccessControl(
      accessibility: accessibility,
      flags: flags
    )
  }

  func copyMatching(
    _ query: CFDictionary
  ) -> (status: OSStatus, result: CFTypeRef?) {
    copyQueries.append(query as NSDictionary as! [String: Any])
    return (copyStatus, copyResult)
  }

  func add(_ attributes: CFDictionary) -> OSStatus {
    addQueries.append(attributes as NSDictionary as! [String: Any])
    return addStatus
  }

  func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
    updateQueries.append(
      (
        query as NSDictionary as! [String: Any],
        attributes as NSDictionary as! [String: Any]
      )
    )
    return errSecSuccess
  }

  func delete(_ query: CFDictionary) -> OSStatus {
    deleteQueries.append(query as NSDictionary as! [String: Any])
    return deleteStatus
  }
}

private enum TestKeychainError: LocalizedError {
  case failed

  var errorDescription: String? { "Access control failed." }
}
