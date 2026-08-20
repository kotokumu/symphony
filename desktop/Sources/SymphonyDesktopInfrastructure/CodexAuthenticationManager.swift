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
  func stop(codexHome: URL) async throws
}

extension CodexCommandExecuting {
  public func stop(codexHome: URL) async throws {}
}

public actor CodexAuthenticationManager {
  private enum OperationOutcome: Sendable {
    case state(CodexAuthenticationState)
    case cancelled
    case failed(String)
    case terminationFailed(String)
  }

  private struct Operation {
    let generation: UUID
    let codexHome: URL
    let task: Task<OperationOutcome, Never>
  }

  private let executor: any CodexCommandExecuting
  private var states: [Namespace.ID: CodexAuthenticationState] = [:]
  private var operations: [Namespace.ID: Operation] = [:]
  private var quiescedNamespaces: Set<Namespace.ID> = []
  private var startSuspensionCount = 0
  private var applicationTerminationRequested = false
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
    let codexHome = codexHome(in: namespaceDirectory)
    guard
      let operation = beginOperation(
        for: namespaceID,
        codexHome: codexHome,
        task: { [executor] in
          do {
            let result = try await executor.execute(
              CodexCommandInvocation(arguments: ["login", "status"], codexHome: codexHome)
            )
            return .state(Self.statusState(from: result))
          } catch is CancellationError {
            return .cancelled
          } catch CodexCLIError.stopFailed {
            return .terminationFailed(CodexCLIError.stopFailed.localizedDescription)
          } catch {
            return .failed(
              "Codex authentication could not be checked: \(error.localizedDescription)")
          }
        })
    else {
      return
    }
    await complete(operation, for: namespaceID)
  }

  public func signIn(namespaceID: Namespace.ID, namespaceDirectory: URL) async {
    let codexHome = codexHome(in: namespaceDirectory)
    guard canBeginOperation(for: namespaceID) else {
      return
    }
    publish(.authenticating, for: namespaceID)
    guard
      let operation = beginOperation(
        for: namespaceID,
        codexHome: codexHome,
        task: { [executor] in
          do {
            let loginResult = try await executor.execute(
              CodexCommandInvocation(arguments: ["login"], codexHome: codexHome)
            )
            guard loginResult.status == 0 else {
              return .state(
                .failed(message: "Codex sign-in failed: \(Self.message(from: loginResult))")
              )
            }
            let statusResult = try await executor.execute(
              CodexCommandInvocation(arguments: ["login", "status"], codexHome: codexHome)
            )
            return .state(Self.statusState(from: statusResult))
          } catch is CancellationError {
            return .cancelled
          } catch CodexCLIError.stopFailed {
            return .terminationFailed(CodexCLIError.stopFailed.localizedDescription)
          } catch {
            return .failed("Codex sign-in failed: \(error.localizedDescription)")
          }
        })
    else {
      return
    }
    await complete(operation, for: namespaceID)
  }

  public func signOut(namespaceID: Namespace.ID, namespaceDirectory: URL) async {
    let codexHome = codexHome(in: namespaceDirectory)
    guard
      let operation = beginOperation(
        for: namespaceID,
        codexHome: codexHome,
        task: { [executor] in
          do {
            let result = try await executor.execute(
              CodexCommandInvocation(arguments: ["logout"], codexHome: codexHome)
            )
            if result.status == 0 || Self.normalized(result.output).contains("not logged in") {
              return .state(.signedOut)
            }
            return .state(
              .failed(message: "Codex sign-out failed: \(Self.message(from: result))")
            )
          } catch is CancellationError {
            return .cancelled
          } catch CodexCLIError.stopFailed {
            return .terminationFailed(CodexCLIError.stopFailed.localizedDescription)
          } catch {
            return .failed("Codex sign-out failed: \(error.localizedDescription)")
          }
        })
    else {
      return
    }
    await complete(operation, for: namespaceID)
  }

  public func quiesce(namespaceID: Namespace.ID) async throws {
    quiescedNamespaces.insert(namespaceID)
    try await cancelOperation(for: namespaceID)
  }

  public func resume(namespaceID: Namespace.ID) {
    quiescedNamespaces.remove(namespaceID)
  }

  public func removeNamespace(_ namespaceID: Namespace.ID) {
    guard operations[namespaceID] == nil else {
      return
    }
    states.removeValue(forKey: namespaceID)
    quiescedNamespaces.remove(namespaceID)
  }

  public func cancelAll() async throws {
    startSuspensionCount += 1
    defer { startSuspensionCount -= 1 }
    try await drainOperations()
  }

  public func shutdownForApplicationTermination() async throws {
    applicationTerminationRequested = true
    do {
      try await drainOperations()
    } catch {
      applicationTerminationRequested = false
      throw error
    }
  }

  public func resumeAfterApplicationTerminationFailure() {
    applicationTerminationRequested = false
  }

  private func drainOperations() async throws {
    var failedToStop = false
    for namespaceID in Array(operations.keys) {
      do {
        try await cancelOperation(for: namespaceID)
      } catch {
        failedToStop = true
      }
    }
    if failedToStop {
      throw CodexAuthenticationLifecycleError.stopFailed
    }
  }

  private func cancelOperation(for namespaceID: Namespace.ID) async throws {
    guard let operation = operations[namespaceID] else {
      return
    }
    operation.task.cancel()
    let outcome = await operation.task.value
    if case .terminationFailed(let message) = outcome {
      do {
        try await executor.stop(codexHome: operation.codexHome)
      } catch {
        publish(.failed(message: message), for: namespaceID)
        throw CodexAuthenticationLifecycleError.stopFailed
      }
    }
    if operations[namespaceID]?.generation == operation.generation {
      operations.removeValue(forKey: namespaceID)
    }
    if case .cancelled = outcome, states[namespaceID] == .authenticating {
      publish(.signedOut, for: namespaceID)
    }
  }

  private func canBeginOperation(for namespaceID: Namespace.ID) -> Bool {
    startSuspensionCount == 0
      && !applicationTerminationRequested
      && !quiescedNamespaces.contains(namespaceID)
      && operations[namespaceID] == nil
  }

  private func beginOperation(
    for namespaceID: Namespace.ID,
    codexHome: URL,
    task: @escaping @Sendable () async -> OperationOutcome
  ) -> Operation? {
    guard canBeginOperation(for: namespaceID) else {
      return nil
    }
    let operation = Operation(
      generation: UUID(),
      codexHome: codexHome,
      task: Task { await task() }
    )
    operations[namespaceID] = operation
    return operation
  }

  private func complete(_ operation: Operation, for namespaceID: Namespace.ID) async {
    let outcome = await operation.task.value
    guard operations[namespaceID]?.generation == operation.generation else {
      return
    }
    switch outcome {
    case .state(let state):
      operations.removeValue(forKey: namespaceID)
      publish(state, for: namespaceID)
    case .cancelled:
      operations.removeValue(forKey: namespaceID)
    case .failed(let message):
      operations.removeValue(forKey: namespaceID)
      publish(.failed(message: message), for: namespaceID)
    case .terminationFailed(let message):
      publish(.failed(message: message), for: namespaceID)
    }
  }

  private func codexHome(in namespaceDirectory: URL) -> URL {
    namespaceDirectory.appendingPathComponent("CodexHome", isDirectory: true)
  }

  private static func statusState(from result: CodexCommandResult) -> CodexAuthenticationState {
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

  private static func message(from result: CodexCommandResult) -> String {
    let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? "The Codex command exited with status \(result.status)." : message
  }

  private static func normalized(_ message: String) -> String {
    message.lowercased()
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

public enum CodexAuthenticationLifecycleError: LocalizedError, Sendable {
  case stopFailed

  public var errorDescription: String? {
    "The Codex authentication process could not be stopped safely. Try again before deleting the namespace or quitting."
  }
}
