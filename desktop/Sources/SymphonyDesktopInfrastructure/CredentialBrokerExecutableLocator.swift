import Foundation

public struct CredentialBrokerExecutableLocator {
  private let fileManager: FileManager
  private let bundleURL: URL

  public init(
    fileManager: FileManager = .default,
    bundleURL: URL = Bundle.main.bundleURL
  ) {
    self.fileManager = fileManager
    self.bundleURL = bundleURL
  }

  public func locate() -> URL? {
    let packagedHelper = bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Helpers", isDirectory: true)
      .appendingPathComponent("SymphonyCredentialBroker")
    return fileManager.isExecutableFile(atPath: packagedHelper.path) ? packagedHelper : nil
  }
}
