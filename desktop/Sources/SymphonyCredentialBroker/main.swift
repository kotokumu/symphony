import Darwin
import Foundation
import SymphonyCredentialBrokerKit
import SymphonyCredentialBrokerProtocol

@main
struct SymphonyCredentialBrokerMain {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 2, arguments[0] == "git-credential" {
      Foundation.exit(BrokerGitCredentialHelper.run(action: arguments[1]))
    }
    if arguments.count >= 2, arguments[0] == "git-runner" {
      Foundation.exit(runGitProcess(executable: arguments[1], arguments: Array(arguments.dropFirst(2))))
    }
    guard arguments.count == 2, let namespaceID = UUID(uuidString: arguments[1]) else {
      FileHandle.standardError.write(Data("Invalid broker invocation.\n".utf8))
      Foundation.exit(64)
    }

    do {
      try ParentCodeSignatureBrokerClientAuthorizer().authorizeCaller()
    } catch {
      if arguments[0] == "serve" {
        write(CredentialBrokerHandshake.failed(message: error.localizedDescription))
      }
      Foundation.exit(77)
    }

    let session = NamespaceCredentialSession(namespaceID: namespaceID)
    switch arguments[0] {
    case "serve":
      do {
        try await session.unlock(
          reason: "Unlock protected credentials for this Symphony namespace."
        )
        write(CredentialBrokerHandshake.unlocked)
        let signalShutdown = BrokerSignalShutdown {
          try await session.lock()
        }
        defer { signalShutdown.cancel() }
        try await serve(session)
      } catch {
        write(CredentialBrokerHandshake.failed(message: error.localizedDescription))
        Foundation.exit(1)
      }
    case "purge":
      do {
        try await session.removeStoredCredential()
      } catch {
        FileHandle.standardError.write(Data("Protected credential cleanup failed.\n".utf8))
        Foundation.exit(1)
      }
    default:
      FileHandle.standardError.write(Data("Unknown broker operation.\n".utf8))
      Foundation.exit(64)
    }
  }

  private static func runGitProcess(executable: String, arguments: [String]) -> Int32 {
    guard Darwin.setpgid(0, 0) == 0 else { return 1 }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    } catch {
      return 1
    }
  }

  private static func serve(_ session: NamespaceCredentialSession) async throws {
    while let data = try BrokerStandardInput.readLine(maximumBytes: 65_536) {
      do {
        let command = try JSONDecoder().decode(CredentialBrokerCommand.self, from: data)
        try command.validatePayloadShape()
        switch command.operation {
        case .signChallenge:
          guard let challenge = command.payload else {
            throw BrokerCommandError.missingPayload
          }
          write(CredentialBrokerResult.signature(try await session.signChallenge(challenge)))
        case .configureGitHubApp:
          guard let configuration = command.githubAppConfiguration else {
            throw BrokerCommandError.missingPayload
          }
          try await session.configureGitHubApp(
            appID: configuration.appID,
            privateKeyFilePath: configuration.privateKeyFilePath
          )
          write(CredentialBrokerResult.githubAppConfigured)
        case .listGitHubInstallations:
          write(
            CredentialBrokerResult.githubInstallations(
              try await session.listGitHubInstallations()
            )
          )
        case .listGitHubRepositories:
          guard let installationID = command.installationID else {
            throw BrokerCommandError.missingPayload
          }
          write(
            CredentialBrokerResult.githubRepositories(
              try await session.listGitHubRepositories(installationID: installationID)
            )
          )
        case .authorizeGitHubRepository:
          guard let authorization = command.githubRepositoryAuthorization else {
            throw BrokerCommandError.missingPayload
          }
          try await session.authorizeGitHubRepository(authorization)
          write(CredentialBrokerResult.githubRepositoryAuthorized)
        case .performGitHubIssueRequest:
          guard let request = command.githubIssueRequest else {
            throw BrokerCommandError.missingPayload
          }
          write(
            CredentialBrokerResult.githubIssueResponse(
              try await session.performGitHubIssueRequest(request)
            )
          )
        case .performGitHubGitOperation:
          guard let request = command.githubGitRequest else {
            throw BrokerCommandError.missingPayload
          }
          write(
            CredentialBrokerResult.githubGitResult(
              try await session.performGitHubGitOperation(request)
            )
          )
        case .lock:
          try await session.lock()
          write(CredentialBrokerResult.locked)
          return
        }
      } catch let error as GitHubRepositoryAPIError {
        write(CredentialBrokerResult.githubCapabilityFailed(error.failure))
      } catch let error as GitHubRepositoryAccessError {
        write(CredentialBrokerResult.githubCapabilityFailed(error.failure))
      } catch {
        write(CredentialBrokerResult.failed(message: error.localizedDescription))
      }
    }
    try await session.lock()
  }

  private static func write<Value: Encodable>(_ value: Value) {
    do {
      var data = try JSONEncoder().encode(value)
      if data.count > CredentialBrokerProtocolLimits.maximumResponseBytes {
        data = try JSONEncoder().encode(
          CredentialBrokerResult.failed(
            message: "The credential broker result exceeded the safe response limit."
          )
        )
      }
      data.append(0x0A)
      FileHandle.standardOutput.write(data)
    } catch {
      FileHandle.standardError.write(Data("Broker response failed.\n".utf8))
      Foundation.exit(1)
    }
  }
}

private final class BrokerSignalShutdown: @unchecked Sendable {
  private let term: DispatchSourceSignal
  private let interrupt: DispatchSourceSignal

  init(action: @escaping @Sendable () async throws -> Void) {
    Darwin.signal(SIGTERM, SIG_IGN)
    Darwin.signal(SIGINT, SIG_IGN)
    term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
    interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
    let handler: @Sendable () -> Void = {
      _ = Task {
        do {
          try await action()
          Foundation.exit(0)
        } catch {
          Foundation.exit(1)
        }
      }
    }
    term.setEventHandler(handler: DispatchWorkItem(block: handler))
    interrupt.setEventHandler(handler: DispatchWorkItem(block: handler))
    term.resume()
    interrupt.resume()
  }

  func cancel() {
    term.cancel()
    interrupt.cancel()
  }
}

private enum BrokerStandardInput {
  static func readLine(maximumBytes: Int) throws -> Data? {
    var line = Data()
    while line.count <= maximumBytes {
      guard let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty else {
        return line.isEmpty ? nil : line
      }
      if byte[byte.startIndex] == 0x0A {
        return line
      }
      line.append(byte)
    }
    throw BrokerCommandError.messageTooLarge
  }
}

private enum BrokerCommandError: LocalizedError {
  case missingPayload
  case messageTooLarge

  var errorDescription: String? {
    switch self {
    case .missingPayload:
      "The credential capability request is missing its payload."
    case .messageTooLarge:
      "The credential capability request is too large."
    }
  }
}
