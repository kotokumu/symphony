import Foundation

public struct Namespace: Hashable, Identifiable, Sendable {
  public let id: UUID
  public private(set) var name: NamespaceName
  public private(set) var platformConnection: PlatformConnection?

  public init(
    id: UUID = UUID(),
    name: NamespaceName,
    platformConnection: PlatformConnection? = nil
  ) {
    self.id = id
    self.name = name
    self.platformConnection = platformConnection
  }

  mutating func rename(to name: NamespaceName) {
    self.name = name
  }

  mutating func connect(to connection: PlatformConnection) throws {
    guard platformConnection == nil else {
      throw NamespaceConnectionError.alreadyConnected
    }
    platformConnection = connection
  }

  @discardableResult
  mutating func disconnectPlatform() throws -> PlatformConnection {
    guard let platformConnection else {
      throw NamespaceConnectionError.notConnected
    }
    self.platformConnection = nil
    return platformConnection
  }
}

public enum NamespaceConnectionError: LocalizedError, Equatable, Sendable {
  case alreadyConnected
  case notConnected

  public var errorDescription: String? {
    switch self {
    case .alreadyConnected:
      "This namespace already has a platform connection. Disconnect it before connecting another platform."
    case .notConnected:
      "This namespace does not have a platform connection."
    }
  }
}
