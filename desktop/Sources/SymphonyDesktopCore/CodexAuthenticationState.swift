import Foundation

public enum CodexAuthenticationState: Equatable, Sendable {
  case signedOut
  case authenticating
  case signedIn
  case expired(message: String)
  case failed(message: String)
}

public struct CodexAuthenticationEvent: Equatable, Sendable {
  public let namespaceID: Namespace.ID
  public let state: CodexAuthenticationState

  public init(namespaceID: Namespace.ID, state: CodexAuthenticationState) {
    self.namespaceID = namespaceID
    self.state = state
  }
}
