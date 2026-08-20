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
