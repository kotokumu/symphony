import Foundation

@MainActor
struct CredentialSecurityBarrier {
  typealias Operation = @MainActor () async throws -> Void

  let quiesceGitHub: Operation
  let lockCredentials: Operation

  func secure() async throws {
    let quiescence = Task { await Self.run(quiesceGitHub) }
    let locking = Task { await Self.run(lockCredentials) }
    let results = await [quiescence.value, locking.value]
    let failures = results.compactMap { result -> String? in
      if case .failure(let message) = result { return message }
      return nil
    }
    guard failures.isEmpty else {
      throw CredentialSecurityBarrierError.failed(failures)
    }
  }

  private enum Result {
    case success
    case failure(String)
  }

  private static func run(_ operation: Operation) async -> Result {
    do {
      try await operation()
      return .success
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

private enum CredentialSecurityBarrierError: LocalizedError {
  case failed([String])

  var errorDescription: String? {
    switch self {
    case .failed(let failures):
      "Namespace credentials could not be secured: \(failures.joined(separator: " "))"
    }
  }
}
