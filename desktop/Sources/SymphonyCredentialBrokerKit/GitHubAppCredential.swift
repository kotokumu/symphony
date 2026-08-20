import Foundation
import Security

struct StoredGitHubAppCredential: Codable {
  private static let currentVersion = 1

  let version: Int
  let appID: Int64
  var privateKeyDER: Data

  init(appID: Int64, pemData: Data) throws {
    guard appID > 0 else {
      throw GitHubAppCredentialError.invalidAppID
    }
    guard pemData.count <= 128 * 1_024 else {
      throw GitHubAppCredentialError.privateKeyTooLarge
    }
    let der = try Self.decodePEM(pemData)
    guard Self.makePrivateKey(from: der) != nil else {
      throw GitHubAppCredentialError.invalidPrivateKey
    }
    version = Self.currentVersion
    self.appID = appID
    privateKeyDER = der
  }

  func encodeForStorage() throws -> Data {
    try JSONEncoder().encode(self)
  }

  static func decode(from data: Data) throws -> Self {
    let credential: Self
    do {
      credential = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw GitHubAppCredentialError.notConfigured
    }
    guard credential.version == currentVersion, credential.appID > 0,
      makePrivateKey(from: credential.privateKeyDER) != nil
    else {
      throw GitHubAppCredentialError.invalidStoredCredential
    }
    return credential
  }

  mutating func clear() {
    privateKeyDER.resetBytes(in: privateKeyDER.startIndex..<privateKeyDER.endIndex)
  }

  func makeJWT(now: Date = Date()) throws -> String {
    guard let key = Self.makePrivateKey(from: privateKeyDER) else {
      throw GitHubAppCredentialError.invalidStoredCredential
    }
    let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
    let issuedAt = Int64(now.timeIntervalSince1970) - 60
    let expiresAt = issuedAt + 9 * 60
    let payload = try JSONSerialization.data(
      withJSONObject: ["iat": issuedAt, "exp": expiresAt, "iss": appID]
    )
    let signingInput = "\(header.base64URLEncodedString()).\(payload.base64URLEncodedString())"
    var signingError: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        key,
        .rsaSignatureMessagePKCS1v15SHA256,
        Data(signingInput.utf8) as CFData,
        &signingError
      ) as Data?
    else {
      throw GitHubAppCredentialError.signingFailed(
        signingError?.takeRetainedValue().localizedDescription
          ?? "The GitHub App credential could not sign a request."
      )
    }
    return "\(signingInput).\(signature.base64URLEncodedString())"
  }

  private static func decodePEM(_ data: Data) throws -> Data {
    guard let pem = String(data: data, encoding: .utf8) else {
      throw GitHubAppCredentialError.invalidPrivateKey
    }
    let lines = pem.split(whereSeparator: \Character.isNewline)
    let body = lines
      .filter { !$0.hasPrefix("-----BEGIN") && !$0.hasPrefix("-----END") }
      .joined()
    guard !body.isEmpty, let der = Data(base64Encoded: body) else {
      throw GitHubAppCredentialError.invalidPrivateKey
    }
    return der
  }

  private static func makePrivateKey(from der: Data) -> SecKey? {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

public enum GitHubAppCredentialError: LocalizedError, Sendable {
  case invalidAppID
  case privateKeyTooLarge
  case invalidPrivateKey
  case notConfigured
  case invalidStoredCredential
  case signingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidAppID:
      "Enter the numeric GitHub App ID shown in the app settings."
    case .privateKeyTooLarge:
      "The selected GitHub App private key file is unexpectedly large."
    case .invalidPrivateKey:
      "The selected file is not a valid RSA private key from a GitHub App."
    case .notConfigured:
      "GitHub App credentials have not been configured for this namespace."
    case .invalidStoredCredential:
      "The stored GitHub App credential is unreadable. Disconnect and configure the app again."
    case .signingFailed(let message):
      "GitHub App authentication failed: \(message)"
    }
  }
}
