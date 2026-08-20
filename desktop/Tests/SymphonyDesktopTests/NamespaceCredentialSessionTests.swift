import Foundation
import LocalAuthentication
import XCTest

@testable import SymphonyCredentialBrokerKit

final class NamespaceCredentialSessionTests: XCTestCase {
  func testFirstUnlockAuthorizesStoresAndRetainsCredentialUntilLock() async throws {
    let namespaceID = UUID()
    let storage = RecordingCredentialStorage()
    let authorizer = RecordingUnlockAuthorizer()
    let session = NamespaceCredentialSession(
      namespaceID: namespaceID,
      authorizer: authorizer,
      storage: storage,
      credentialGenerator: { Data([1, 2, 3, 4]) }
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
        return Data([1])
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
      credentialGenerator: { Data([1, 2, 3]) }
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

  init(credentials: [UUID: Data] = [:]) {
    self.credentials = credentials
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
