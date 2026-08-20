import Foundation
import SymphonyDesktopInfrastructure
import XCTest

final class CodexCLICommandExecutorTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  func testSuppliesOnlyTheNamespaceCodexHomeAndRemovesInheritedCredentials() async throws {
    let executor = CodexCLICommandExecutor(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      environment: [
        "PATH": "/usr/bin:/bin",
        "CODEX_HOME": "/global/codex-home",
        "OPENAI_API_KEY": "inherited-openai-key",
        "CODEX_ACCESS_TOKEN": "inherited-access-token",
        "CODEX_API_KEY": "inherited-codex-key",
      ]
    )
    let codexHome = temporaryDirectory.appendingPathComponent("CodexHome")

    let result = try await executor.execute(
      CodexCommandInvocation(arguments: [], codexHome: codexHome)
    )

    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("CODEX_HOME=\(codexHome.path)"))
    XCTAssertFalse(result.output.contains("/global/codex-home"))
    XCTAssertFalse(result.output.contains("inherited-openai-key"))
    XCTAssertFalse(result.output.contains("inherited-access-token"))
    XCTAssertFalse(result.output.contains("inherited-codex-key"))
    let attributes = try FileManager.default.attributesOfItem(atPath: codexHome.path)
    XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
  }

  func testReportsAnUnavailableExecutableWithoutCreatingCodexHome() async throws {
    let codexHome = temporaryDirectory.appendingPathComponent("CodexHome")
    let executor = CodexCLICommandExecutor(executableURL: nil)

    do {
      _ = try await executor.execute(
        CodexCommandInvocation(arguments: ["login", "status"], codexHome: codexHome)
      )
      XCTFail("Expected the missing executable to fail")
    } catch let error as CodexCLIError {
      XCTAssertEqual(
        error.localizedDescription,
        "The Codex CLI could not be found. Install Codex and try again."
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: codexHome.path))
  }
}
