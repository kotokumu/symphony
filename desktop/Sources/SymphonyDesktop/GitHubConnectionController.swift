import Combine
import Foundation
import SymphonyDesktopCore

protocol GitHubConnectionBrokering: Sendable {
  func configureGitHubApp(
    appID: Int64,
    privateKeyFileURL: URL,
    namespaceID: Namespace.ID
  ) async throws
  func discoverGitHubInstallations(
    namespaceID: Namespace.ID
  ) async throws -> [GitHubInstallation]
  func discoverGitHubRepositories(
    installationID: Int64,
    namespaceID: Namespace.ID
  ) async throws -> [GitHubRepository]
}

protocol GitHubCredentialCleaning: Sendable {
  func setupStarted(_ namespaceID: Namespace.ID) async throws
  func cleanup(_ namespaceID: Namespace.ID) async throws -> String?
  func connectionCommitted(_ namespaceID: Namespace.ID) async throws
}

enum GitHubConnectionOperationState: Equatable {
  case idle
  case loadingInstallations
  case choosingInstallation(appID: Int64, [GitHubInstallation])
  case loadingRepositories
  case choosingRepository(
    appID: Int64,
    installation: GitHubInstallation,
    repositories: [GitHubRepository]
  )
  case saving
  case checking
  case verified
  case failed(String)
}

@MainActor
final class GitHubConnectionController: ObservableObject {
  typealias SaveConnection = @MainActor (GitHubConnection) async throws -> Void
  typealias RemoveConnection = @MainActor () async throws -> Void

  @Published private var states: [Namespace.ID: GitHubConnectionOperationState] = [:]

  private enum OperationKind {
    case setup
    case check
    case disconnect
    case cancelling
  }

  private struct Operation {
    let id: UUID
    let kind: OperationKind
    var inFlight: Task<Void, Never>?
  }

  private enum DisconnectOutcome {
    case disconnected(String?)
    case retained(any Error)
    case rollbackFailed(String)
  }

  private enum ConnectOutcome {
    case connected
    case connectedWithBookkeepingWarning(String)
    case saveFailed(any Error)
    case rollbackFailed(String)
  }

  private let broker: any GitHubConnectionBrokering
  private let credentialCleanup: any GitHubCredentialCleaning
  private var operations: [Namespace.ID: Operation] = [:]
  private var cancellationTasks: [Namespace.ID: Task<Result<String?, Error>, Never>] = [:]
  private var admissionSuspended = false

  init(
    broker: any GitHubConnectionBrokering,
    credentialCleanup: any GitHubCredentialCleaning
  ) {
    self.broker = broker
    self.credentialCleanup = credentialCleanup
  }

  func state(for namespaceID: Namespace.ID) -> GitHubConnectionOperationState {
    states[namespaceID] ?? .idle
  }

  var isAdmissionSuspended: Bool { admissionSuspended }

  func beginConnection(
    namespaceID: Namespace.ID,
    appIDText: String,
    privateKeyFileURL: URL
  ) async {
    guard let appID = Int64(appIDText), appID > 0 else {
      states[namespaceID] = .failed(GitHubConnectionSetupError.invalidAppID.localizedDescription)
      return
    }
    if operations[namespaceID] != nil, case .failed = state(for: namespaceID) {
      guard await cancelSetup(namespaceID: namespaceID) == nil else { return }
    }
    guard let operationID = reserve(.setup, namespaceID: namespaceID) else { return }
    states[namespaceID] = .loadingInstallations
    let task = Task { [broker, credentialCleanup] in
      do {
        try await credentialCleanup.setupStarted(namespaceID)
        try await broker.configureGitHubApp(
          appID: appID,
          privateKeyFileURL: privateKeyFileURL,
          namespaceID: namespaceID
        )
        let installations = try await broker.discoverGitHubInstallations(namespaceID: namespaceID)
        guard !installations.isEmpty else {
          throw GitHubConnectionSetupError.noInstallations
        }
        return Result<[GitHubInstallation], Error>.success(installations)
      } catch {
        return .failure(error)
      }
    }
    track(task, namespaceID: namespaceID, operationID: operationID)
    let result = await task.value
    clearInFlight(namespaceID: namespaceID, operationID: operationID)
    guard owns(operationID, namespaceID: namespaceID) else { return }
    switch result {
    case .success(let installations):
      states[namespaceID] = .choosingInstallation(
        appID: appID,
        installations.sorted { $0.accountLogin.localizedCaseInsensitiveCompare($1.accountLogin) == .orderedAscending }
      )
    case .failure(let error):
      states[namespaceID] = .failed(error.localizedDescription)
    }
  }

  func chooseInstallation(
    _ installation: GitHubInstallation,
    namespaceID: Namespace.ID
  ) async {
    guard let operationID = setupOperationID(namespaceID), operationIsIdle(namespaceID) else {
      states[namespaceID] = .failed(GitHubConnectionSetupError.selectionExpired.localizedDescription)
      return
    }
    guard case .choosingInstallation(let appID, let installations) = state(for: namespaceID),
      installations.contains(installation)
    else {
      states[namespaceID] = .failed(GitHubConnectionSetupError.selectionExpired.localizedDescription)
      return
    }
    do {
      try GitHubPermissionRequirements.validate(installation)
    } catch {
      states[namespaceID] = .failed(error.localizedDescription)
      return
    }
    states[namespaceID] = .loadingRepositories
    let task = Task { [broker] in
      do {
        let repositories = try await broker.discoverGitHubRepositories(
          installationID: installation.id,
          namespaceID: namespaceID
        )
        guard !repositories.isEmpty else {
          throw GitHubConnectionSetupError.noRepositories
        }
        return Result<[GitHubRepository], Error>.success(repositories)
      } catch {
        return .failure(error)
      }
    }
    track(task, namespaceID: namespaceID, operationID: operationID)
    let result = await task.value
    clearInFlight(namespaceID: namespaceID, operationID: operationID)
    guard owns(operationID, namespaceID: namespaceID) else { return }
    switch result {
    case .success(let repositories):
      states[namespaceID] = .choosingRepository(
        appID: appID,
        installation: installation,
        repositories: repositories.sorted {
          $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
      )
    case .failure(let error):
      states[namespaceID] = .failed(error.localizedDescription)
    }
  }

  func connect(
    _ repository: GitHubRepository,
    namespaceID: Namespace.ID,
    save: @escaping SaveConnection
  ) async throws {
    guard let operationID = setupOperationID(namespaceID), operationIsIdle(namespaceID) else {
      throw GitHubConnectionSetupError.selectionExpired
    }
    guard
      case .choosingRepository(let appID, let installation, let repositories) = state(
        for: namespaceID
      ),
      repositories.contains(repository)
    else {
      throw GitHubConnectionSetupError.selectionExpired
    }
    let connection = try GitHubConnection(
      appID: appID,
      installationID: installation.id,
      accountLogin: installation.accountLogin,
      repositoryID: repository.id,
      repositoryFullName: repository.fullName,
      repositoryURL: repository.htmlURL
    )
    states[namespaceID] = .saving
    let task = Task { [credentialCleanup] in
      do {
        try await save(connection)
      } catch {
        let saveError = error
        do {
          if let warning = try await credentialCleanup.cleanup(namespaceID) {
            return ConnectOutcome.rollbackFailed("The connection was not saved. \(warning)")
          }
        } catch {
          return .rollbackFailed(
            "The connection was not saved, and protected credential cleanup also failed: \(error.localizedDescription)"
          )
        }
        return .saveFailed(saveError)
      }
      do {
        try await credentialCleanup.connectionCommitted(namespaceID)
        return .connected
      } catch {
        return .connectedWithBookkeepingWarning(
          "The GitHub connection was saved, but cleanup bookkeeping could not finish. Symphony will reconcile it after restart: \(error.localizedDescription)"
        )
      }
    }
    track(task, namespaceID: namespaceID, operationID: operationID)
    let outcome = await task.value
    clearInFlight(namespaceID: namespaceID, operationID: operationID)
    guard owns(operationID, namespaceID: namespaceID) else {
      throw GitHubConnectionSetupError.selectionExpired
    }
    switch outcome {
    case .connected:
      states[namespaceID] = .idle
      release(namespaceID: namespaceID, operationID: operationID)
    case .connectedWithBookkeepingWarning(let message):
      states[namespaceID] = .failed(message)
      release(namespaceID: namespaceID, operationID: operationID)
    case .saveFailed(let error):
      states[namespaceID] = .failed(error.localizedDescription)
      release(namespaceID: namespaceID, operationID: operationID)
      throw error
    case .rollbackFailed(let message):
      states[namespaceID] = .failed(message)
      throw GitHubConnectionSetupError.rollbackFailed
    }
  }

  func disconnect(
    namespaceID: Namespace.ID,
    remove: @escaping RemoveConnection
  ) async throws -> String? {
    guard let operationID = reserve(.disconnect, namespaceID: namespaceID) else {
      throw GitHubConnectionSetupError.operationInProgress
    }
    states[namespaceID] = .saving
    let task = Task { [credentialCleanup] in
      var markerWasStaged = false
      do {
        try await credentialCleanup.setupStarted(namespaceID)
        markerWasStaged = true
        try await remove()
      } catch {
        let primaryError = error
        if markerWasStaged {
          do {
            try await credentialCleanup.connectionCommitted(namespaceID)
          } catch {
            return DisconnectOutcome.rollbackFailed(
              "The GitHub connection was retained, but cleanup bookkeeping could not be rolled back: \(error.localizedDescription)"
            )
          }
        }
        return .retained(primaryError)
      }

      do {
        return .disconnected(try await credentialCleanup.cleanup(namespaceID))
      } catch {
        return .disconnected(
          "The namespace was disconnected, but protected credential cleanup is pending: \(error.localizedDescription)"
        )
      }
    }
    track(task, namespaceID: namespaceID, operationID: operationID)
    let outcome = await task.value
    clearInFlight(namespaceID: namespaceID, operationID: operationID)
    guard owns(operationID, namespaceID: namespaceID) else {
      throw GitHubConnectionSetupError.operationInProgress
    }
    release(namespaceID: namespaceID, operationID: operationID)
    switch outcome {
    case .retained(let error):
      states[namespaceID] = .failed(error.localizedDescription)
      throw error
    case .rollbackFailed(let message):
      states[namespaceID] = .failed(message)
      throw GitHubConnectionSetupError.rollbackFailed
    case .disconnected(let warning):
      if let warning {
        states[namespaceID] = .failed(warning)
        return warning
      }
      states[namespaceID] = .idle
      return nil
    }
  }

  func check(_ connection: GitHubConnection, namespaceID: Namespace.ID) async {
    guard let operationID = reserve(.check, namespaceID: namespaceID) else { return }
    states[namespaceID] = .checking
    let task = Task { [broker] in
      do {
        let installations = try await broker.discoverGitHubInstallations(namespaceID: namespaceID)
        guard let installation = installations.first(where: { $0.id == connection.installationID }) else {
          throw GitHubConnectionSetupError.installationRevoked
        }
        try GitHubPermissionRequirements.validate(installation)
        let repositories = try await broker.discoverGitHubRepositories(
          installationID: installation.id,
          namespaceID: namespaceID
        )
        guard repositories.contains(where: { $0.id == connection.repositoryID }) else {
          throw GitHubConnectionSetupError.repositoryRevoked
        }
        return Result<Void, Error>.success(())
      } catch {
        return .failure(error)
      }
    }
    track(task, namespaceID: namespaceID, operationID: operationID)
    let result = await task.value
    clearInFlight(namespaceID: namespaceID, operationID: operationID)
    guard owns(operationID, namespaceID: namespaceID) else { return }
    switch result {
    case .success:
      states[namespaceID] = .verified
    case .failure(let error):
      states[namespaceID] = .failed(error.localizedDescription)
    }
    release(namespaceID: namespaceID, operationID: operationID)
  }

  func cancelSetup(namespaceID: Namespace.ID) async -> String? {
    guard state(for: namespaceID) != .idle else { return nil }
    guard let previous = operations[namespaceID] else {
      states[namespaceID] = .idle
      return nil
    }
    guard previous.kind == .setup || previous.kind == .cancelling else {
      return GitHubConnectionSetupError.operationInProgress.localizedDescription
    }
    if previous.kind == .cancelling, let existing = cancellationTasks[namespaceID] {
      return cancellationWarning(from: await existing.value)
    }
    let operationID = UUID()
    operations[namespaceID] = Operation(id: operationID, kind: .cancelling, inFlight: nil)
    let task = Task { [credentialCleanup] in
      await previous.inFlight?.value
      do {
        return Result<String?, Error>.success(
          try await credentialCleanup.cleanup(namespaceID)
        )
      } catch {
        return .failure(error)
      }
    }
    cancellationTasks[namespaceID] = task
    track(task, namespaceID: namespaceID, operationID: operationID)
    let result = await task.value
    clearInFlight(namespaceID: namespaceID, operationID: operationID)
    guard owns(operationID, namespaceID: namespaceID) else { return nil }
    switch result {
    case .success(let warning):
      if let warning {
        states[namespaceID] = .failed(warning)
        cancellationTasks.removeValue(forKey: namespaceID)
        return warning
      }
      states[namespaceID] = .idle
      release(namespaceID: namespaceID, operationID: operationID)
      return nil
    case .failure(let error):
      let message = "Connection setup was cancelled, but protected credential cleanup is pending: \(error.localizedDescription)"
      states[namespaceID] = .failed(message)
      cancellationTasks.removeValue(forKey: namespaceID)
      return message
    }
  }

  func quiesceAll() async throws {
    admissionSuspended = true
    var failures: [String] = []
    for namespaceID in Array(operations.keys) {
      guard let operation = operations[namespaceID] else { continue }
      if (operation.kind == .setup || operation.kind == .cancelling),
        state(for: namespaceID) != .saving
      {
        if let warning = await cancelSetup(namespaceID: namespaceID) {
          failures.append(warning)
        }
      } else {
        await operation.inFlight?.value
        if let current = operations[namespaceID], current.id == operation.id,
          current.kind == .setup, state(for: namespaceID) != .saving
        {
          let warning = await cancelSetup(namespaceID: namespaceID)
          if let warning { failures.append(warning) }
        }
      }
    }
    guard failures.isEmpty else {
      throw GitHubConnectionSetupError.quiesceFailed(failures)
    }
  }

  func resumeAfterSecurityOperation() {
    admissionSuspended = false
  }

  private func reserve(_ kind: OperationKind, namespaceID: Namespace.ID) -> UUID? {
    guard !admissionSuspended, operations[namespaceID] == nil else { return nil }
    let id = UUID()
    operations[namespaceID] = Operation(id: id, kind: kind, inFlight: nil)
    return id
  }

  private func cancellationWarning(from result: Result<String?, Error>) -> String? {
    switch result {
    case .success(let warning):
      return warning
    case .failure(let error):
      return "Connection setup was cancelled, but protected credential cleanup is pending: \(error.localizedDescription)"
    }
  }

  private func setupOperationID(_ namespaceID: Namespace.ID) -> UUID? {
    guard let operation = operations[namespaceID], operation.kind == .setup else { return nil }
    return operation.id
  }

  private func operationIsIdle(_ namespaceID: Namespace.ID) -> Bool {
    operations[namespaceID]?.inFlight == nil
  }

  private func owns(_ operationID: UUID, namespaceID: Namespace.ID) -> Bool {
    operations[namespaceID]?.id == operationID
  }

  private func track<Value>(
    _ task: Task<Value, Never>,
    namespaceID: Namespace.ID,
    operationID: UUID
  ) {
    guard owns(operationID, namespaceID: namespaceID) else { return }
    operations[namespaceID]?.inFlight = Task { _ = await task.value }
  }

  private func clearInFlight(namespaceID: Namespace.ID, operationID: UUID) {
    guard owns(operationID, namespaceID: namespaceID) else { return }
    operations[namespaceID]?.inFlight = nil
  }

  private func release(namespaceID: Namespace.ID, operationID: UUID) {
    guard owns(operationID, namespaceID: namespaceID) else { return }
    operations.removeValue(forKey: namespaceID)
    cancellationTasks.removeValue(forKey: namespaceID)
  }
}

enum GitHubPermissionRequirements {
  static func validate(_ installation: GitHubInstallation) throws {
    guard !installation.isSuspended else {
      throw GitHubConnectionSetupError.installationSuspended
    }
    var missing: [String] = []
    if installation.permissions["issues"] != "write" {
      missing.append("Issues: Read and write")
    }
    if installation.permissions["contents"] != "write" {
      missing.append("Contents: Read and write")
    }
    guard missing.isEmpty else {
      throw GitHubConnectionSetupError.missingPermissions(missing)
    }
  }

}

enum GitHubConnectionSetupError: LocalizedError, Equatable {
  case invalidAppID
  case noInstallations
  case noRepositories
  case selectionExpired
  case installationSuspended
  case missingPermissions([String])
  case installationRevoked
  case repositoryRevoked
  case rollbackFailed
  case operationInProgress
  case quiesceFailed([String])

  var errorDescription: String? {
    switch self {
    case .invalidAppID:
      "Enter the numeric GitHub App ID shown in the app settings."
    case .noInstallations:
      "This GitHub App has no accessible installations. Install it on an account and try again."
    case .noRepositories:
      "This installation has no accessible repositories. Grant repository access and try again."
    case .selectionExpired:
      "The GitHub selection is no longer available. Start the connection again."
    case .installationSuspended:
      "This GitHub App installation is suspended. Restore it in GitHub before connecting."
    case .missingPermissions(let permissions):
      "Update the GitHub App installation permissions: \(permissions.joined(separator: ", "))."
    case .installationRevoked:
      "The selected GitHub App installation is no longer accessible. Reinstall the app or disconnect this namespace."
    case .repositoryRevoked:
      "The selected repository is no longer accessible to this GitHub App installation. Update repository access or disconnect this namespace."
    case .rollbackFailed:
      "The GitHub connection could not be saved or cleaned up safely. Retry credential cleanup before connecting again."
    case .operationInProgress:
      "Another GitHub connection operation is already running for this namespace."
    case .quiesceFailed(let failures):
      "GitHub connection operations could not be secured: \(failures.joined(separator: " "))"
    }
  }
}
