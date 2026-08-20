import Foundation
import XCTest

@testable import SymphonyDesktopInfrastructure

final class CredentialBrokerExecutableLocatorTests: XCTestCase {
  func testFindsPackagedHelperInsideApplicationBundle() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CredentialBrokerExecutableLocatorTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let application = directory.appendingPathComponent("Symphony.app")
    let helper = application
      .appendingPathComponent("Contents/Helpers")
      .appendingPathComponent("SymphonyCredentialBroker")
    try FileManager.default.createDirectory(
      at: helper.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let locator = CredentialBrokerExecutableLocator(
      bundleURL: application
    )

    XCTAssertEqual(locator.locate(), helper)
  }

  func testReturnsNilWhenNoExecutableHelperExists() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-\(UUID().uuidString)")
    let locator = CredentialBrokerExecutableLocator(bundleURL: missing)

    XCTAssertNil(locator.locate())
  }
}
