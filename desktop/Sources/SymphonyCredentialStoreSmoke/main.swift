import Foundation
import SymphonyCredentialBrokerKit

@main
struct SymphonyCredentialStoreSmokeMain {
  static func main() async {
    let namespaceID = UUID()
    let session = NamespaceCredentialSession(namespaceID: namespaceID)
    do {
      try await session.unlock(
        reason: "Verify Symphony development credential storage."
      )
      try await session.lock()
      try await session.unlock(
        reason: "Verify Symphony can reload protected development credentials."
      )
      try await session.removeStoredCredential()
      FileHandle.standardOutput.write(Data("Credential storage smoke check passed.\n".utf8))
    } catch {
      try? await session.removeStoredCredential()
      FileHandle.standardError.write(
        Data("Credential storage smoke check failed: \(error.localizedDescription)\n".utf8)
      )
      Foundation.exit(1)
    }
  }
}
