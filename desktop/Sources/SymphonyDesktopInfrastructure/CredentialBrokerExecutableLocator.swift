import Foundation

public struct CredentialBrokerExecutableLocator {
  private let fileManager: FileManager
  private let processExecutableURL: URL?
  private let bundleURL: URL

  public init(
    fileManager: FileManager = .default,
    processExecutableURL: URL? = Bundle.main.executableURL,
    bundleURL: URL = Bundle.main.bundleURL
  ) {
    self.fileManager = fileManager
    self.processExecutableURL = processExecutableURL
    self.bundleURL = bundleURL
  }

  public func locate() -> URL? {
    let packagedHelper = bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Helpers", isDirectory: true)
      .appendingPathComponent("SymphonyCredentialBroker")
    let developmentHelper = processExecutableURL?
      .deletingLastPathComponent()
      .appendingPathComponent("SymphonyCredentialBroker")

    return [packagedHelper, developmentHelper]
      .compactMap { $0 }
      .first { fileManager.isExecutableFile(atPath: $0.path) }
  }
}
