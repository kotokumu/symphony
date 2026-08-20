import Foundation
import CryptoKit
import LocalAuthentication
import Security
import XCTest

@testable import SymphonyCredentialBrokerKit
@testable import SymphonyCredentialBrokerProtocol

final class NamespaceCredentialSessionTests: XCTestCase {
  func testFirstUnlockAuthorizesStoresAndRetainsCredentialUntilLock() async throws {
    let namespaceID = UUID()
    let storage = RecordingCredentialStorage()
    let authorizer = RecordingUnlockAuthorizer()
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: authorizer,
      storage: storage,
      credentialGenerator: { SecureSecretBuffer(copying: Data([1, 2, 3, 4])) }
    )

    try await session.unlock(reason: "Test unlock")

    XCTAssertEqual(storage.storedCredential(for: namespaceID), Data([1, 2, 3, 4]))
    let retainedByteCount = await session.retainedByteCount
    let reasons = await authorizer.reasons
    XCTAssertEqual(retainedByteCount, 4)
    XCTAssertEqual(reasons, ["Test unlock"])

    await session.lock()

    let lockedByteCount = await session.retainedByteCount
    XCTAssertEqual(lockedByteCount, 0)
  }

  func testLaterUnlockLoadsPersistedCredentialWithoutGeneratingReplacement() async throws {
    let namespaceID = UUID()
    let storage = RecordingCredentialStorage(
      credentials: [namespaceID: Data([9, 8, 7])]
    )
    let generator = InvocationCounter()
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: RecordingUnlockAuthorizer(),
      storage: storage,
      credentialGenerator: {
        generator.increment()
        return SecureSecretBuffer(copying: Data([1]))
      }
    )

    try await session.unlock(reason: "Test unlock")

    let retainedByteCount = await session.retainedByteCount
    XCTAssertEqual(retainedByteCount, 3)
    XCTAssertEqual(generator.value, 0)
  }

  func testAuthorizationDenialDoesNotAccessStorageOrRetainMaterial() async {
    let namespaceID = UUID()
    let storage = RecordingCredentialStorage()
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: RecordingUnlockAuthorizer(error: TestUnlockError.denied),
      storage: storage,
      credentialGenerator: { SecureSecretBuffer(copying: Data([1, 2, 3])) }
    )

    do {
      try await session.unlock(reason: "Test unlock")
      XCTFail("Expected authorization to fail")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Test unlock denied.")
    }

    XCTAssertEqual(storage.loadCount, 0)
    XCTAssertEqual(storage.storeCount, 0)
    let retainedByteCount = await session.retainedByteCount
    XCTAssertEqual(retainedByteCount, 0)
  }

  func testRemovingNamespaceClearsMemoryAndDeletesStoredCredential() async throws {
    let namespaceID = UUID()
    let storage = RecordingCredentialStorage(
      credentials: [namespaceID: Data([4, 5, 6])]
    )
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: RecordingUnlockAuthorizer(),
      storage: storage
    )
    try await session.unlock(reason: "Test unlock")

    try await session.removeStoredCredential()

    let retainedByteCount = await session.retainedByteCount
    XCTAssertEqual(retainedByteCount, 0)
    XCTAssertNil(storage.storedCredential(for: namespaceID))
  }

  func testSigningChallengeReturnsOnlyDerivedCapabilityResult() async throws {
    let namespaceID = UUID()
    let storedCredential = Data([1, 2, 3, 4])
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: RecordingUnlockAuthorizer(),
      storage: RecordingCredentialStorage(credentials: [namespaceID: storedCredential])
    )
    try await session.unlock(reason: "Test unlock")
    let challenge = Data("challenge".utf8)

    let signature = try await session.signChallenge(challenge)

    let expected = Data(
      HMAC<SHA256>.authenticationCode(
        for: challenge,
        using: SymmetricKey(data: storedCredential)
      )
    )
    XCTAssertEqual(signature, expected)
    XCTAssertNotEqual(signature, storedCredential)

    await session.lock()
    do {
      _ = try await session.signChallenge(challenge)
      XCTFail("Expected locked capability error")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Protected namespace credentials are locked.")
    }
  }

  func testSecureBufferOverwritesItsAllocationWhenCleared() {
    let buffer = SecureSecretBuffer(copying: Data([7, 8, 9]))

    buffer.clear()

    XCTAssertEqual(buffer.bytesForTesting, [0, 0, 0])
  }

  func testStorageFailureOverwritesGeneratedMaterialBeforeReturning() async {
    let namespaceID = UUID()
    let generated = SecureSecretBuffer(copying: Data([5, 6, 7]))
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: RecordingUnlockAuthorizer(),
      storage: RecordingCredentialStorage(storeError: TestCredentialStorageError.failed),
      credentialGenerator: { generated }
    )

    do {
      try await session.unlock(reason: "Test unlock")
      XCTFail("Expected storage failure")
    } catch {}

    XCTAssertEqual(generated.bytesForTesting, [0, 0, 0])
  }

  func testConfiguresGitHubPrivateKeyAndExposesOnlyBrokeredDiscoveryResults() async throws {
    let namespaceID = UUID()
    let storage = RecordingCredentialStorage(credentials: [namespaceID: Data([1, 2, 3])])
    let githubAPI = RecordingGitHubAppAPI()
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: RecordingUnlockAuthorizer(),
      storage: storage,
      githubAPI: githubAPI
    )
    let privateKeyURL = try makePrivateKeyPEM()
    defer { try? FileManager.default.removeItem(at: privateKeyURL) }
    try await session.unlock(reason: "Test unlock")

    try await session.configureGitHubApp(
      appID: 10,
      privateKeyFilePath: privateKeyURL.path
    )
    let installations = try await session.listGitHubInstallations()
    let repositories = try await session.listGitHubRepositories(installationID: 20)

    XCTAssertEqual(installations.first?.accountLogin, "octo")
    XCTAssertEqual(repositories.first?.fullName, "octo/research")
    var stored = try StoredGitHubAppCredential.decode(
      from: XCTUnwrap(storage.storedCredential(for: namespaceID))
    )
    XCTAssertEqual(stored.appID, 10)
    stored.clear()
    let jwtValues = await githubAPI.jwtValues
    XCTAssertEqual(jwtValues.count, 2)
    XCTAssertTrue(jwtValues.allSatisfy { $0.split(separator: ".").count == 3 })
    let privateKeyText = try String(contentsOf: privateKeyURL, encoding: .utf8)
    XCTAssertTrue(jwtValues.allSatisfy { !$0.contains(privateKeyText) })
  }

  func testInvalidGitHubPrivateKeyDoesNotReplaceStoredCredential() async throws {
    let namespaceID = UUID()
    let original = Data([9, 8, 7])
    let storage = RecordingCredentialStorage(credentials: [namespaceID: original])
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: RecordingUnlockAuthorizer(),
      storage: storage
    )
    let invalidURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("invalid-github-key-\(UUID().uuidString)")
    try Data("not a private key".utf8).write(to: invalidURL)
    defer { try? FileManager.default.removeItem(at: invalidURL) }
    try await session.unlock(reason: "Test unlock")

    do {
      try await session.configureGitHubApp(appID: 10, privateKeyFilePath: invalidURL.path)
      XCTFail("Expected invalid private key")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("not a valid RSA private key"))
    }
    XCTAssertEqual(storage.storedCredential(for: namespaceID), original)
  }

  func testGitHubJWTContainsRequiredClaimsAndValidRS256Signature() throws {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2_048,
    ]
    var error: Unmanaged<CFError>?
    let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
    let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
    let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(privateKey, &error) as Data?)
    let pem = Data(
      "-----BEGIN RSA PRIVATE KEY-----\n\(der.base64EncodedString())\n-----END RSA PRIVATE KEY-----\n".utf8
    )
    var credential = try StoredGitHubAppCredential(appID: 12345, pemData: pem)
    defer { credential.clear() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    let jwt = try credential.makeJWT(now: now)
    let parts = jwt.split(separator: ".")
    XCTAssertEqual(parts.count, 3)
    let header = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try decodeBase64URL(parts[0])) as? [String: String]
    )
    let claims = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try decodeBase64URL(parts[1])) as? [String: Any]
    )
    XCTAssertEqual(header["alg"], "RS256")
    XCTAssertEqual(header["typ"], "JWT")
    XCTAssertEqual((claims["iss"] as? NSNumber)?.int64Value, 12345)
    XCTAssertEqual((claims["iat"] as? NSNumber)?.int64Value, 1_999_999_940)
    XCTAssertEqual((claims["exp"] as? NSNumber)?.int64Value, 2_000_000_480)
    let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
    let signature = try decodeBase64URL(parts[2])
    XCTAssertTrue(
      SecKeyVerifySignature(
        publicKey,
        .rsaSignatureMessagePKCS1v15SHA256,
        signingInput as CFData,
        signature as CFData,
        &error
      )
    )
  }

  func testReplacementStorageFailurePreservesStoredAndInMemoryCredential() async throws {
    let namespaceID = UUID()
    let original = Data([9, 8, 7])
    let storage = RecordingCredentialStorage(
      credentials: [namespaceID: original],
      replaceError: TestCredentialStorageError.failed
    )
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: RecordingUnlockAuthorizer(),
      storage: storage
    )
    let privateKeyURL = try makePrivateKeyPEM()
    defer { try? FileManager.default.removeItem(at: privateKeyURL) }
    try await session.unlock(reason: "Test unlock")

    do {
      try await session.configureGitHubApp(appID: 10, privateKeyFilePath: privateKeyURL.path)
      XCTFail("Expected replacement failure")
    } catch {}

    XCTAssertEqual(storage.storedCredential(for: namespaceID), original)
    let signature = try await session.signChallenge(Data("challenge".utf8))
    let expected = Data(
      HMAC<SHA256>.authenticationCode(
        for: Data("challenge".utf8),
        using: SymmetricKey(data: original)
      )
    )
    XCTAssertEqual(signature, expected)
  }

  func testOversizedPrivateKeyFileIsRejectedBeforeReplacement() async throws {
    let namespaceID = UUID()
    let original = Data([1, 2, 3])
    let storage = RecordingCredentialStorage(credentials: [namespaceID: original])
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: RecordingUnlockAuthorizer(),
      storage: storage
    )
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("oversized-github-key-\(UUID().uuidString)")
    try Data(repeating: 0x41, count: 128 * 1_024 + 1).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    try await session.unlock(reason: "Test unlock")

    do {
      try await session.configureGitHubApp(appID: 10, privateKeyFilePath: url.path)
      XCTFail("Expected bounded private key failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("unexpectedly large"))
    }
    XCTAssertEqual(storage.storedCredential(for: namespaceID), original)
  }

  private func decodeBase64URL(_ value: Substring) throws -> Data {
    var base64 = String(value)
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return try XCTUnwrap(Data(base64Encoded: base64))
  }

  private func makePrivateKeyPEM() throws -> URL {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2_048,
    ]
    var error: Unmanaged<CFError>?
    let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
    let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, &error) as Data?)
    let base64 = der.base64EncodedString(options: [.lineLength64Characters])
    let pem = "-----BEGIN RSA PRIVATE KEY-----\n\(base64)\n-----END RSA PRIVATE KEY-----\n"
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("github-app-\(UUID().uuidString).pem")
    try Data(pem.utf8).write(to: url, options: .atomic)
    return url
  }
}

private actor RecordingGitHubAppAPI: GitHubAppAPIRequesting {
  private(set) var jwtValues: [String] = []

  func listInstallations(jwt: String) -> [GitHubInstallationDescriptor] {
    jwtValues.append(jwt)
    return [
      GitHubInstallationDescriptor(
        id: 20,
        accountLogin: "octo",
        accountType: "Organization",
        permissions: ["issues": "read", "contents": "write"],
        isSuspended: false
      )
    ]
  }

  func listRepositories(
    installationID: Int64,
    jwt: String
  ) -> [GitHubRepositoryDescriptor] {
    jwtValues.append(jwt)
    return [
      GitHubRepositoryDescriptor(
        id: 30,
        fullName: "octo/research",
        htmlURL: URL(string: "https://github.com/octo/research")!,
        isPrivate: true
      )
    ]
  }
}

private actor RecordingUnlockAuthorizer: NamespaceUnlockAuthorizing {
  private(set) var reasons: [String] = []
  private let error: Error?

  init(error: Error? = nil) {
    self.error = error
  }

  func authorize(reason: String) async throws -> NamespaceUnlockAuthorization {
    reasons.append(reason)
    if let error { throw error }
    let authorization = NamespaceUnlockAuthorization(context: LAContext())
    return authorization
  }
}

private final class RecordingCredentialStorage: NamespaceCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var credentials: [UUID: Data]
  private var loadInvocations = 0
  private var storeInvocations = 0
  private let storeError: Error?
  private let replaceError: Error?

  init(
    credentials: [UUID: Data] = [:],
    storeError: Error? = nil,
    replaceError: Error? = nil
  ) {
    self.credentials = credentials
    self.storeError = storeError
    self.replaceError = replaceError
  }

  func load(
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws -> Data? {
    lock.withLock {
      loadInvocations += 1
      return credentials[namespaceID]
    }
  }

  func store(
    _ credential: Data,
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws {
    lock.withLock {
      storeInvocations += 1
      if storeError != nil { return }
      credentials[namespaceID] = credential
    }
    if let storeError { throw storeError }
  }

  func replace(
    _ credential: Data,
    namespaceID: UUID,
    authorization: NamespaceUnlockAuthorization
  ) throws {
    if let replaceError { throw replaceError }
    lock.withLock {
      credentials[namespaceID] = credential
    }
  }

  func removeAll(namespaceID: UUID) throws {
    _ = lock.withLock {
      credentials.removeValue(forKey: namespaceID)
    }
  }

  func storedCredential(for namespaceID: UUID) -> Data? {
    lock.withLock { credentials[namespaceID] }
  }

  var loadCount: Int { lock.withLock { loadInvocations } }
  var storeCount: Int { lock.withLock { storeInvocations } }
}

private final class InvocationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

private enum TestUnlockError: LocalizedError {
  case denied

  var errorDescription: String? { "Test unlock denied." }
}

private enum TestCredentialStorageError: Error {
  case failed
}
