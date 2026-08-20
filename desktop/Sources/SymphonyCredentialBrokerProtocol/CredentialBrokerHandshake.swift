import Foundation

public enum CredentialBrokerHandshake: Codable, Equatable, Sendable {
  case unlocked
  case failed(message: String)

  private enum CodingKeys: String, CodingKey {
    case status
    case message
  }

  private enum Status: String, Codable {
    case unlocked
    case failed
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Status.self, forKey: .status) {
    case .unlocked:
      self = .unlocked
    case .failed:
      self = .failed(message: try container.decode(String.self, forKey: .message))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .unlocked:
      try container.encode(Status.unlocked, forKey: .status)
    case .failed(let message):
      try container.encode(Status.failed, forKey: .status)
      try container.encode(message, forKey: .message)
    }
  }
}

public struct CredentialBrokerCommand: Codable, Equatable, Sendable {
  public enum Operation: String, Codable, Sendable {
    case signChallenge
    case lock
  }

  public let operation: Operation
  public let payload: Data?

  public init(operation: Operation, payload: Data? = nil) {
    self.operation = operation
    self.payload = payload
  }

  public static func signChallenge(_ challenge: Data) -> Self {
    Self(operation: .signChallenge, payload: challenge)
  }

  public static let lock = Self(operation: .lock)
}

public enum CredentialBrokerResult: Codable, Equatable, Sendable {
  case signature(Data)
  case locked
  case failed(message: String)

  private enum CodingKeys: String, CodingKey {
    case status
    case payload
    case message
  }

  private enum Status: String, Codable {
    case signature
    case locked
    case failed
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Status.self, forKey: .status) {
    case .signature:
      self = .signature(try container.decode(Data.self, forKey: .payload))
    case .locked:
      self = .locked
    case .failed:
      self = .failed(message: try container.decode(String.self, forKey: .message))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .signature(let signature):
      try container.encode(Status.signature, forKey: .status)
      try container.encode(signature, forKey: .payload)
    case .locked:
      try container.encode(Status.locked, forKey: .status)
    case .failed(let message):
      try container.encode(Status.failed, forKey: .status)
      try container.encode(message, forKey: .message)
    }
  }
}
