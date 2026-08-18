import Foundation

public struct NamespaceName: Codable, Hashable, Sendable {
  public let value: String

  public init(validating value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else {
      throw NamespaceNameError.empty
    }

    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw NamespaceNameError.controlCharacter
    }

    guard value == trimmed else {
      throw NamespaceNameError.surroundingWhitespace
    }

    guard value.count <= 64 else {
      throw NamespaceNameError.tooLong
    }

    self.value = value
  }

  var comparisonKey: String {
    value.precomposedStringWithCanonicalMapping.lowercased()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(validating: container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public enum NamespaceNameError: LocalizedError, Equatable, Sendable {
  case empty
  case surroundingWhitespace
  case controlCharacter
  case tooLong

  public var errorDescription: String? {
    switch self {
    case .empty:
      "Enter a namespace name."
    case .surroundingWhitespace:
      "Remove spaces from the beginning or end of the name."
    case .controlCharacter:
      "Namespace names cannot contain control characters."
    case .tooLong:
      "Use 64 characters or fewer."
    }
  }
}
