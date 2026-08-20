import Foundation
import SymphonyCredentialBrokerKit
import SymphonyCredentialBrokerProtocol

@main
struct SymphonyCredentialBrokerMain {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
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

  private static func serve(_ session: NamespaceCredentialSession) async throws {
    while let data = try BrokerStandardInput.readLine(maximumBytes: 65_536) {
      do {
        let command = try JSONDecoder().decode(CredentialBrokerCommand.self, from: data)
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
        case .lock:
          await session.lock()
          write(CredentialBrokerResult.locked)
          return
        }
      } catch {
        write(CredentialBrokerResult.failed(message: error.localizedDescription))
      }
    }
    await session.lock()
  }

  private static func write<Value: Encodable>(_ value: Value) {
    do {
      var data = try JSONEncoder().encode(value)
      data.append(0x0A)
      FileHandle.standardOutput.write(data)
    } catch {
      FileHandle.standardError.write(Data("Broker response failed.\n".utf8))
      Foundation.exit(1)
    }
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
