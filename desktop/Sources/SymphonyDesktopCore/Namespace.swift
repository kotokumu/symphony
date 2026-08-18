import Foundation

public struct Namespace: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public private(set) var name: NamespaceName

  public init(id: UUID = UUID(), name: NamespaceName) {
    self.id = id
    self.name = name
  }

  mutating func rename(to name: NamespaceName) {
    self.name = name
  }
}
