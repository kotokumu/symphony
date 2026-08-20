import Foundation
import XCTest

@testable import SymphonyDesktopInfrastructure

final class CredentialBrokerExecutableLocatorTests: XCTestCase {
  func testFindsDevelopmentHelperBesideDesktopExecutable() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CredentialBrokerExecutableLocatorTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let desktop = directory.appendingPathComponent("SymphonyDesktop")
    let helper = directory.appendingPathComponent("SymphonyCredentialBroker")
    try Data().write(to: desktop)
    try Data().write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let locator = CredentialBrokerExecutableLocator(
      processExecutableURL: desktop,
      bundleURL: directory.appendingPathComponent("NotAnApp")
    )

    XCTAssertEqual(locator.locate(), helper)
  }

  func testReturnsNilWhenNoExecutableHelperExists() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-\(UUID().uuidString)")
    let locator = CredentialBrokerExecutableLocator(
      processExecutableURL: missing.appendingPathComponent("SymphonyDesktop"),
      bundleURL: missing
    )

    XCTAssertNil(locator.locate())
  }
}
