import Foundation
import LocalAuthentication

public final class NamespaceUnlockAuthorization: @unchecked Sendable {
  private let authenticationContext: any NamespaceDeviceOwnerAuthenticationContext
  var context: LAContext { authenticationContext.localAuthenticationContext }

  public init(context: LAContext = LAContext()) {
    authenticationContext = SystemNamespaceDeviceOwnerAuthenticationContext(context: context)
  }

  init(authenticationContext: any NamespaceDeviceOwnerAuthenticationContext) {
    self.authenticationContext = authenticationContext
  }

  public func invalidate() {
    authenticationContext.invalidate()
  }
}

public protocol NamespaceDeviceOwnerAuthenticationContext: Sendable {
  var localAuthenticationContext: LAContext { get }
  func canEvaluatePolicy(_ policy: LAPolicy, error: inout NSError?) -> Bool
  func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool
  func invalidate()
}

public final class SystemNamespaceDeviceOwnerAuthenticationContext:
  NamespaceDeviceOwnerAuthenticationContext,
  @unchecked Sendable
{
  public let localAuthenticationContext: LAContext

  public init(context: LAContext = LAContext()) {
    localAuthenticationContext = context
  }

  public func canEvaluatePolicy(_ policy: LAPolicy, error: inout NSError?) -> Bool {
    localAuthenticationContext.canEvaluatePolicy(policy, error: &error)
  }

  public func evaluatePolicy(
    _ policy: LAPolicy,
    localizedReason: String
  ) async throws -> Bool {
    try await localAuthenticationContext.evaluatePolicy(
      policy,
      localizedReason: localizedReason
    )
  }

  public func invalidate() {
    localAuthenticationContext.invalidate()
  }
}

public protocol NamespaceUnlockAuthorizing: Sendable {
  func authorize(reason: String) async throws -> NamespaceUnlockAuthorization
}

public struct LocalAuthenticationNamespaceUnlockAuthorizer: NamespaceUnlockAuthorizing {
  public typealias ContextFactory = @Sendable () -> any NamespaceDeviceOwnerAuthenticationContext

  private let contextFactory: ContextFactory

  public init(
    contextFactory: @escaping ContextFactory = {
      SystemNamespaceDeviceOwnerAuthenticationContext()
    }
  ) {
    self.contextFactory = contextFactory
  }

  public func authorize(reason: String) async throws -> NamespaceUnlockAuthorization {
    let context = contextFactory()
    let authorization = NamespaceUnlockAuthorization(authenticationContext: context)
    var evaluationError: NSError?
    guard
      context.canEvaluatePolicy(
        .deviceOwnerAuthentication,
        error: &evaluationError
      )
    else {
      authorization.invalidate()
      throw NamespaceUnlockAuthorizationError.unavailable(
        evaluationError?.localizedDescription ?? "Device owner authentication is unavailable."
      )
    }

    let granted: Bool
    do {
      granted = try await context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: reason
      )
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
    guard granted else {
      authorization.invalidate()
      throw NamespaceUnlockAuthorizationError.denied
    }
    return authorization
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
