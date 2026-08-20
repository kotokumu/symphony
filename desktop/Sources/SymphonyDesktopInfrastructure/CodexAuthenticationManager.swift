import Foundation
import SymphonyDesktopCore

public struct CodexCommandInvocation: Equatable, Sendable {
  public let arguments: [String]
  public let codexHome: URL

  public init(arguments: [String], codexHome: URL) {
    self.arguments = arguments
    self.codexHome = codexHome
  }
}

public struct CodexCommandResult: Equatable, Sendable {
  public let status: Int32
  public let output: String

  public init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }
}

public protocol CodexCommandExecuting: Sendable {
  func execute(_ invocation: CodexCommandInvocation) async throws -> CodexCommandResult
}

public actor CodexAuthenticationManager {
  private let executor: any CodexCommandExecuting
  private var states: [Namespace.ID: CodexAuthenticationState] = [:]
  private var activeOperations: Set<Namespace.ID> = []
  private var eventContinuations: [UUID: AsyncStream<CodexAuthenticationEvent>.Continuation] = [:]

  public init(executor: any CodexCommandExecuting) {
    self.executor = executor
  }

  public func events() -> AsyncStream<CodexAuthenticationEvent> {
    let subscriberID = UUID()
    return AsyncStream { continuation in
      eventContinuations[subscriberID] = continuation
      continuation.onTermination = { [weak self] _ in
        Task {
          await self?.removeEventContinuation(subscriberID)
        }
      }
    }
  }

  public func state(for namespaceID: Namespace.ID) -> CodexAuthenticationState {
    states[namespaceID] ?? .signedOut
  }

  public func refresh(namespaceID: Namespace.ID, namespaceDirectory: URL) async {
    guard beginOperation(for: namespaceID) else {
      return
    }
    defer { finishOperation(for: namespaceID) }

    do {
      let result = try await execute(
        ["login", "status"],
        namespaceDirectory: namespaceDirectory
      )
      publish(statusState(from: result), for: namespaceID)
    } catch is CancellationError {
      return
    } catch {
      publish(
        .failed(
          message: "Codex authentication could not be checked: \(error.localizedDescription)"),
        for: namespaceID
      )
    }
  }

  public func signIn(namespaceID: Namespace.ID, namespaceDirectory: URL) async {
    guard beginOperation(for: namespaceID) else {
      return
    }
    defer { finishOperation(for: namespaceID) }
    publish(.authenticating, for: namespaceID)

    do {
      let loginResult = try await execute(["login"], namespaceDirectory: namespaceDirectory)
      guard loginResult.status == 0 else {
        publish(
          .failed(message: "Codex sign-in failed: \(message(from: loginResult))"),
          for: namespaceID
        )
        return
      }

      let statusResult = try await execute(
        ["login", "status"],
        namespaceDirectory: namespaceDirectory
      )
      publish(statusState(from: statusResult), for: namespaceID)
    } catch is CancellationError {
      publish(.signedOut, for: namespaceID)
    } catch {
      publish(
        .failed(message: "Codex sign-in failed: \(error.localizedDescription)"),
        for: namespaceID
      )
    }
  }

  public func signOut(namespaceID: Namespace.ID, namespaceDirectory: URL) async {
    guard beginOperation(for: namespaceID) else {
      return
    }
    defer { finishOperation(for: namespaceID) }

    do {
      let result = try await execute(["logout"], namespaceDirectory: namespaceDirectory)
      if result.status == 0 || normalized(result.output).contains("not logged in") {
        publish(.signedOut, for: namespaceID)
      } else {
        publish(
          .failed(message: "Codex sign-out failed: \(message(from: result))"),
          for: namespaceID
        )
      }
    } catch is CancellationError {
      return
    } catch {
      publish(
        .failed(message: "Codex sign-out failed: \(error.localizedDescription)"),
        for: namespaceID
      )
    }
  }

  private func execute(
    _ arguments: [String],
    namespaceDirectory: URL
  ) async throws -> CodexCommandResult {
    try await executor.execute(
      CodexCommandInvocation(
        arguments: arguments,
        codexHome: namespaceDirectory.appendingPathComponent("CodexHome", isDirectory: true)
      )
    )
  }

  private func statusState(from result: CodexCommandResult) -> CodexAuthenticationState {
    let output = message(from: result)
    let normalizedOutput = normalized(output)
    if normalizedOutput.contains("not logged in") {
      return .signedOut
    }
    if normalizedOutput.contains("expired") {
      return .expired(message: output)
    }
    if result.status == 0 {
      return .signedIn
    }
    return .failed(message: "Codex authentication could not be checked: \(output)")
  }

  private func message(from result: CodexCommandResult) -> String {
    let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? "The Codex command exited with status \(result.status)." : message
  }

  private func normalized(_ message: String) -> String {
    message.lowercased()
  }

  private func beginOperation(for namespaceID: Namespace.ID) -> Bool {
    activeOperations.insert(namespaceID).inserted
  }

  private func finishOperation(for namespaceID: Namespace.ID) {
    activeOperations.remove(namespaceID)
  }

  private func publish(_ state: CodexAuthenticationState, for namespaceID: Namespace.ID) {
    states[namespaceID] = state
    let event = CodexAuthenticationEvent(namespaceID: namespaceID, state: state)
    for continuation in eventContinuations.values {
      continuation.yield(event)
    }
  }

  private func removeEventContinuation(_ id: UUID) {
    eventContinuations.removeValue(forKey: id)
  }
}
