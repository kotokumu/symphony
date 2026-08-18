import Foundation

public struct SymphonyExecutableLocator: Sendable {
  public init() {}

  public func locate() -> URL? {
    if let bundled = Bundle.main.url(
      forResource: "symphony",
      withExtension: nil,
      subdirectory: "bin"
    ) {
      return bundled
    }

    let fileManager = FileManager.default
    let currentDirectory = URL(
      fileURLWithPath: fileManager.currentDirectoryPath,
      isDirectory: true
    )
    let candidates = [
      currentDirectory.appendingPathComponent("elixir/bin/symphony"),
      currentDirectory.appendingPathComponent("../elixir/bin/symphony").standardizedFileURL,
    ]
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
  }
}
