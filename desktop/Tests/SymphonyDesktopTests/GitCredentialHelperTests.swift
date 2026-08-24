import Darwin
import Foundation
import XCTest

@testable import SymphonyCredentialBrokerKit
@testable import SymphonyCredentialBrokerProtocol

final class GitCredentialHelperTests: XCTestCase {
  func testCredentialWireFramesRejectUnknownMissingAndMalformedFieldsWithoutCredentialOutput() async throws {
    let fixture = try makeServer()
    let task = Task.detached { fixture.server.serve() }
    defer { fixture.server.stop() }
    let hostileFrames = [
      #"{"action":"get","input":"cHJvdG9jb2w9aHR0cHMK","secret":"exfiltrate"}"#,
      #"{"action":"get"}"#,
      #"{"action":7,"input":false}"#,
    ]

    for frame in hostileFrames {
      try writeSocketLine(Data(frame.utf8), to: fixture.server.clientHandle.fileDescriptor)
      let responseData = try readSocketLine(from: fixture.server.clientHandle.fileDescriptor)
      let response = try JSONDecoder().decode(GitCredentialWireResponse.self, from: responseData)
      XCTAssertFalse(response.succeeded)
      XCTAssertTrue(response.output.isEmpty)
      XCTAssertFalse(String(decoding: responseData, as: UTF8.self).contains("canary-token"))
    }
    for response in [
      #"{"succeeded":true,"output":"","secret":"exfiltrate"}"#,
      #"{"succeeded":true}"#,
      #"{"succeeded":"yes","output":false}"#,
    ] {
      XCTAssertThrowsError(
        try JSONDecoder().decode(GitCredentialWireResponse.self, from: Data(response.utf8))
      )
    }
    fixture.server.stop()
    _ = await task.value
  }
  func testReturnsCredentialOnlyForTheAuthorizedGitHubRepository() async throws {
    let fixture = try makeServer()
    let task = Task.detached { fixture.server.serve() }
    defer { fixture.server.stop() }
    let environment = helperEnvironment(fixture.server)

    let matching = BrokerGitCredentialHelper.exchange(
      action: "get",
      input: Data("protocol=https\nhost=GitHub.com\npath=OCTO/REPO.git\n\n".utf8),
      environment: environment
    )
    XCTAssertEqual(matching.status, 0)
    XCTAssertEqual(
      String(decoding: matching.output, as: UTF8.self),
      "username=x-access-token\npassword=canary-token\n\n"
    )

    for input in [
      "protocol=http\nhost=github.com\npath=octo/repo\n\n",
      "protocol=https\nhost=github.com:443\npath=octo/repo\n\n",
      "protocol=https\nhost=github.com\npath=other/repo\n\n",
      "protocol=https\nhost=github.com\npath=octo/repo%2Fother\n\n",
    ] {
      let rejected = BrokerGitCredentialHelper.exchange(
        action: "get",
        input: Data(input.utf8),
        environment: environment
      )
      XCTAssertNotEqual(rejected.status, 0)
      XCTAssertTrue(rejected.output.isEmpty)
    }
    fixture.server.stop()
    _ = await task.value
  }

  func testStoreDoesNothingAndEraseInvalidatesTheOperation() async throws {
    let fixture = try makeServer()
    let task = Task.detached { fixture.server.serve() }
    let environment = helperEnvironment(fixture.server)

    let store = BrokerGitCredentialHelper.exchange(
      action: "store",
      input: Data("password=must-not-be-stored\n\n".utf8),
      environment: environment
    )
    XCTAssertEqual(store.status, 0)
    XCTAssertTrue(store.output.isEmpty)
    XCTAssertFalse(fixture.server.authenticationWasRejected)

    let erase = BrokerGitCredentialHelper.exchange(
      action: "erase",
      input: Data("protocol=https\n\n".utf8),
      environment: environment
    )
    XCTAssertEqual(erase.status, 0)
    XCTAssertTrue(erase.output.isEmpty)
    XCTAssertTrue(fixture.server.authenticationWasRejected)
    fixture.server.stop()
    _ = await task.value
  }

  func testDirectInvocationAndOversizedInputFailWithoutCredentialOutput() {
    let missing = BrokerGitCredentialHelper.exchange(
      action: "get",
      input: Data("protocol=https\n".utf8),
      environment: [:]
    )
    XCTAssertNotEqual(missing.status, 0)
    XCTAssertTrue(missing.output.isEmpty)

    let oversized = BrokerGitCredentialHelper.exchange(
      action: "get",
      input: Data(repeating: 0x61, count: CredentialBrokerProtocolLimits.maximumGitCredentialInputBytes + 1),
      environment: ["SYMPHONY_GIT_HELPER_FD": "3"]
    )
    XCTAssertNotEqual(oversized.status, 0)
    XCTAssertTrue(oversized.output.isEmpty)
  }

  func testRealGitInvokesTheInheritedCredentialHelperOverTheCapabilityFD() async throws {
    let fixture = try makeServer()
    let serverTask = Task.detached { fixture.server.serve() }
    defer {
      fixture.server.stop()
      try? fixture.server.clientHandle.close()
    }

    let input = Pipe()
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    let helper = ScopedGitCommandRunner.inheritedCredentialHelper
    let gitArguments = [
      "-c", "credential.helper=",
      "-c", "credential.helper=!\(helper)",
      "-c", "credential.useHttpPath=true",
      "credential", "fill",
    ]
    process.arguments = [
      "-c",
      "exec 3<&2; exec 2>/dev/null; exec /usr/bin/git \(gitArguments.map(shellQuote).joined(separator: " "))",
    ]
    process.standardInput = input
    process.standardOutput = output
    // Process exposes only the standard descriptors. Hand the capability socket
    // through stderr, then duplicate it to fd 3 before Git starts.
    process.standardError = fixture.server.clientHandle
    try process.run()

    input.fileHandleForWriting.write(
      Data("protocol=https\nhost=github.com\npath=octo/repo.git\n\n".utf8)
    )
    try input.fileHandleForWriting.close()
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning && Date() < deadline { usleep(10_000) }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      fixture.server.stop()
      _ = await serverTask.value
      XCTFail("git credential helper did not complete within the test deadline")
      return
    }
    let result = output.fileHandleForReading.readDataToEndOfFile()
    fixture.server.closeClientCopy()
    fixture.server.stop()
    _ = await serverTask.value

    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(
      String(decoding: result, as: UTF8.self),
      "protocol=https\nhost=github.com\npath=octo/repo.git\nusername=x-access-token\npassword=canary-token\n"
    )
  }

  func testOversizedWireRequestAndPeerResponseFailWithinTheFrameDeadline() async throws {
    let fixture = try makeServer()
    let serverTask = Task.detached { fixture.server.serve() }
    let requestStart = ContinuousClock.now
    try writeSocketLine(
      Data(repeating: 0x61, count: 32_769),
      to: fixture.server.clientHandle.fileDescriptor
    )
    let failureData = try readSocketLine(from: fixture.server.clientHandle.fileDescriptor)
    let failure = try JSONDecoder().decode(GitCredentialWireResponse.self, from: failureData)
    XCTAssertFalse(failure.succeeded)
    XCTAssertTrue(failure.output.isEmpty)
    XCTAssertLessThan(requestStart.duration(to: .now), .seconds(1))
    fixture.server.stop()
    _ = await serverTask.value

    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    let clientDescriptor = descriptors[0]
    let peerDescriptor = descriptors[1]
    let peer = Task.detached {
      defer { Darwin.close(peerDescriptor) }
      var byte: UInt8 = 0
      while Darwin.recv(peerDescriptor, &byte, 1, 0) == 1, byte != 0x0A {}
      var response = Data(repeating: 0x62, count: 32_769)
      response.append(0x0A)
      response.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let written = Darwin.send(
            peerDescriptor,
            bytes.baseAddress!.advanced(by: offset),
            bytes.count - offset,
            0
          )
          guard written > 0 else { return }
          offset += written
        }
      }
    }
    let responseStart = ContinuousClock.now
    let result = BrokerGitCredentialHelper.exchange(
      action: "get",
      input: Data("protocol=https\nhost=github.com\npath=octo/repo\n\n".utf8),
      environment: ["SYMPHONY_GIT_HELPER_FD": String(clientDescriptor)]
    )
    Darwin.close(clientDescriptor)
    _ = await peer.value
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.isEmpty)
    XCTAssertLessThan(responseStart.duration(to: .now), .seconds(1))
  }

  private func makeServer() throws -> (
    server: PrivateGitCredentialServer,
    credential: OperationCredential,
    root: URL
  ) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("symphony-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let scope = try AuthorizedGitHubRepositoryScope(
      GitHubRepositoryAuthorization(
        appID: 10,
        installationID: 20,
        repositoryID: 30,
        repositoryFullName: "octo/repo",
        repositoryURL: URL(string: "https://github.com/octo/repo")!,
        workspacesRoot: root
      ),
      storedAppID: 10
    )
    let source = SecureSecretBuffer(copying: Data("canary-token".utf8))
    let credential = OperationCredential(copying: source)
    source.clear()
    return (try PrivateGitCredentialServer(scope: scope, credential: credential), credential, root)
  }

  private func helperEnvironment(_ server: PrivateGitCredentialServer) -> [String: String] {
    server.helperEnvironment
  }

  private func writeSocketLine(_ data: Data, to descriptor: Int32) throws {
    var framed = data
    framed.append(0x0A)
    try framed.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
        guard written > 0 else { throw GitCommandRunnerError.authenticationRejected }
        offset += written
      }
    }
  }

  private func readSocketLine(from descriptor: Int32) throws -> Data {
    var result = Data()
    while result.count <= 32_768 {
      var byte: UInt8 = 0
      guard Darwin.recv(descriptor, &byte, 1, 0) == 1 else {
        throw GitCommandRunnerError.authenticationRejected
      }
      if byte == 0x0A { return result }
      result.append(byte)
    }
    throw GitCommandRunnerError.outputTooLarge("")
  }

  private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}
