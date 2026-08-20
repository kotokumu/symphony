import Foundation

public enum NamespaceProcessEnvironment {
  public static let inheritedCredentialNames = [
    "OPENAI_API_KEY",
    "CODEX_ACCESS_TOKEN",
    "CODEX_API_KEY",
    "CODEX_HOME",
  ]

  public static func sanitized(
    _ environment: [String: String],
    codexHome: URL? = nil
  ) -> [String: String] {
    var sanitizedEnvironment = environment
    for name in inheritedCredentialNames {
      sanitizedEnvironment.removeValue(forKey: name)
    }
    if let codexHome {
      sanitizedEnvironment["CODEX_HOME"] = codexHome.path
    }
    return sanitizedEnvironment
  }
}
