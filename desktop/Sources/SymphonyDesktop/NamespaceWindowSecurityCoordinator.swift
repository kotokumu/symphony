import Combine
import Foundation

@MainActor
final class NamespaceWindowSecurityCoordinator: ObservableObject {
  typealias SecurityOperation = () async throws -> Void

  enum State: Equatable {
    case idle
    case securing
    case failed(String)
  }

  @Published private(set) var state: State = .idle

  private let lockCredentials: SecurityOperation
  private let cancelAuthentication: SecurityOperation
  private let stopDaemons: SecurityOperation
  private var task: Task<Void, Never>?

  init(
    lockCredentials: @escaping SecurityOperation,
    cancelAuthentication: @escaping SecurityOperation,
    stopDaemons: @escaping SecurityOperation
  ) {
    self.lockCredentials = lockCredentials
    self.cancelAuthentication = cancelAuthentication
    self.stopDaemons = stopDaemons
  }

  func secureAfterWindowCloses() {
    guard task == nil else { return }
    state = .securing
    task = Task { [weak self] in
      guard let self else { return }
      var failures: [String] = []
      for operation in [lockCredentials, cancelAuthentication, stopDaemons] {
        do {
          try await operation()
        } catch {
          failures.append(error.localizedDescription)
        }
      }
      if failures.isEmpty {
        state = .idle
      } else {
        state = .failed(failures.joined(separator: "\n"))
      }
      task = nil
    }
  }

  func retry() {
    guard case .failed = state else { return }
    secureAfterWindowCloses()
  }

  func waitForCurrentOperation() async {
    await task?.value
  }
}
