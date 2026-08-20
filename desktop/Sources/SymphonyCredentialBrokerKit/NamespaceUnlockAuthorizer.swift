import Foundation
import LocalAuthentication

public final class NamespaceUnlockAuthorization: @unchecked Sendable {
  let context: LAContext

  public init(context: LAContext = LAContext()) {
    self.context = context
  }

  public func invalidate() {
    context.invalidate()
  }
}

public protocol NamespaceUnlockAuthorizing: Sendable {
  func authorize(reason: String) async throws -> NamespaceUnlockAuthorization
}

public struct LocalAuthenticationNamespaceUnlockAuthorizer: NamespaceUnlockAuthorizing {
  public init() {}

  public func authorize(reason: String) async throws -> NamespaceUnlockAuthorization {
    let authorization = NamespaceUnlockAuthorization()
    var evaluationError: NSError?
    guard
      authorization.context.canEvaluatePolicy(
        .deviceOwnerAuthentication,
        error: &evaluationError
      )
    else {
      throw NamespaceUnlockAuthorizationError.unavailable(
        evaluationError?.localizedDescription ?? "Device owner authentication is unavailable."
      )
    }

    do {
      let granted = try await authorization.context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: reason
      )
      guard granted else {
        authorization.invalidate()
        throw NamespaceUnlockAuthorizationError.denied
      }
      return authorization
    } catch {
      authorization.invalidate()
      if let localAuthenticationError = error as? LAError {
        switch localAuthenticationError.code {
        case .userCancel, .appCancel, .systemCancel:
          throw NamespaceUnlockAuthorizationError.cancelled
        default:
          throw NamespaceUnlockAuthorizationError.denied
        }
      }
      throw error
    }
  }
}

public enum NamespaceUnlockAuthorizationError: LocalizedError, Sendable {
  case unavailable(String)
  case cancelled
  case denied

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message):
      "Namespace credentials cannot be unlocked: \(message)"
    case .cancelled:
      "Namespace unlock was cancelled."
    case .denied:
      "Namespace unlock was not authorized."
    }
  }
}
