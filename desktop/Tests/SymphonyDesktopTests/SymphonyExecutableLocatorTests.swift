import Foundation
import XCTest

@testable import SymphonyDesktopInfrastructure

final class SymphonyExecutableLocatorTests: XCTestCase {
  func testFindsDaemonAtPackagedContentsBinPath() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SymphonyExecutableLocatorTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let daemon = directory.appendingPathComponent("Contents/bin/symphony")
    try FileManager.default.createDirectory(
      at: daemon.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: daemon)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemon.path)

    XCTAssertEqual(
      SymphonyExecutableLocator(bundleURL: directory).locate(),
      SymphonyDaemonCommand(executableURL: daemon)
    )
  }
}
