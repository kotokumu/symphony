import Foundation

public struct SymphonyExecutableLocator {
  private let fileManager: FileManager
  private let bundleURL: URL

  public init(
    fileManager: FileManager = .default,
    bundleURL: URL = Bundle.main.bundleURL
  ) {
    self.fileManager = fileManager
    self.bundleURL = bundleURL
  }

  public func locate() -> SymphonyDaemonCommand? {
    let packagedDaemon = bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent("symphony")
    if fileManager.isExecutableFile(atPath: packagedDaemon.path) {
      return SymphonyDaemonCommand(executableURL: packagedDaemon)
    }
    if let bundled = Bundle(url: bundleURL)?.url(
      forResource: "symphony",
      withExtension: nil,
      subdirectory: "bin"
    ), fileManager.isExecutableFile(atPath: bundled.path) {
      return SymphonyDaemonCommand(executableURL: bundled)
    }

    let currentDirectory = URL(
      fileURLWithPath: fileManager.currentDirectoryPath,
      isDirectory: true
    )
    let repositoryRoots = [
      currentDirectory,
      currentDirectory.appendingPathComponent("..").standardizedFileURL,
    ]
    guard
      let repositoryRoot = repositoryRoots.first(where: {
        fileManager.isExecutableFile(
          atPath: $0.appendingPathComponent("elixir/bin/symphony").path
        )
      }),
      let miseURL = miseURL(fileManager: fileManager)
    else {
      return nil
    }

    let daemonURL = repositoryRoot.appendingPathComponent("elixir/bin/symphony")
    return SymphonyDaemonCommand(
      executableURL: miseURL,
      argumentPrefix: ["exec", "--", daemonURL.path],
      workingDirectoryURL: repositoryRoot.appendingPathComponent("elixir", isDirectory: true)
    )
  }

  private func miseURL(fileManager: FileManager) -> URL? {
    let environmentPaths =
      ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":")
      .map(String.init) ?? []
    let candidates =
      environmentPaths.map {
        URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("mise")
      } + [URL(fileURLWithPath: "/opt/homebrew/bin/mise")]
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
  }
}

public struct SymphonyDaemonCommand: Equatable, Sendable {
  public let executableURL: URL
  public let argumentPrefix: [String]
  public let workingDirectoryURL: URL?

  public init(
    executableURL: URL,
    argumentPrefix: [String] = [],
    workingDirectoryURL: URL? = nil
  ) {
    self.executableURL = executableURL
    self.argumentPrefix = argumentPrefix
    self.workingDirectoryURL = workingDirectoryURL
  }
}
