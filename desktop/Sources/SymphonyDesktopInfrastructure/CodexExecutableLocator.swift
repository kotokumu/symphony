import Foundation

public struct CodexExecutableLocator {
  private let environment: [String: String]
  private let fileManager: FileManager

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) {
    self.environment = environment
    self.fileManager = fileManager
  }

  public func locate() -> URL? {
    let pathDirectories = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    let candidateDirectories = pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin"]
    for directory in candidateDirectories {
      let candidate = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent("codex")
      if fileManager.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }
}
