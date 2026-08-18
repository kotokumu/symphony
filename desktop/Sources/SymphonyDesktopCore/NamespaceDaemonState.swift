import Foundation

public enum NamespaceDaemonState: Equatable, Sendable {
  case stopped
  case starting
  case running(endpoint: URL)
  case failed(message: String)
}

public struct NamespaceDaemonEvent: Equatable, Sendable {
  public let namespaceID: Namespace.ID
  public let state: NamespaceDaemonState

  public init(namespaceID: Namespace.ID, state: NamespaceDaemonState) {
    self.namespaceID = namespaceID
    self.state = state
  }
}
