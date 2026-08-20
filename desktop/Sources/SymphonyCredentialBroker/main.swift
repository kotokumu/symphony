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

    let session = NamespaceCredentialSession(namespaceID: namespaceID)
    switch arguments[0] {
    case "serve":
      do {
        try await session.unlock(
          reason: "Unlock protected credentials for this Symphony namespace."
        )
        write(.unlocked)
        while let command = readLine(), command != "lock" {}
        await session.lock()
      } catch {
        write(.failed(message: error.localizedDescription))
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

  private static func write(_ handshake: CredentialBrokerHandshake) {
    do {
      var data = try JSONEncoder().encode(handshake)
      data.append(0x0A)
      FileHandle.standardOutput.write(data)
    } catch {
      FileHandle.standardError.write(Data("Broker response failed.\n".utf8))
      Foundation.exit(1)
    }
  }
}
