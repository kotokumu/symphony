import Foundation

public struct NamespaceDaemonTrackerConfiguration: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case memory
    case github
  }

  public let kind: Kind
  public let repository: String?

  public init(kind: Kind = .memory, repository: String? = nil) {
    self.kind = kind
    self.repository = repository
  }

  public static let memory = Self()

  public static func github(repository: String) -> Self {
    Self(kind: .github, repository: repository)
  }
}
