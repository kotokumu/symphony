import Combine
import Foundation
import SymphonyCredentialBrokerProtocol
import SymphonyDesktopCore

protocol GitHubConnectionBrokering: Sendable {
  func configureGitHubApp(
    appID: Int64,
    privateKeyFileURL: URL,
    namespaceID: Namespace.ID
  ) async throws
  func listGitHubInstallations(
    namespaceID: Namespace.ID
  ) async throws -> [GitHubInstallationDescriptor]
  func listGitHubRepositories(
    installationID: Int64,
    namespaceID: Namespace.ID
  ) async throws -> [GitHubRepositoryDescriptor]
}

protocol GitHubCredentialCleaning: Sendable {
  func setupStarted(_ namespaceID: Namespace.ID) async throws
  func cleanup(_ namespaceID: Namespace.ID) async throws -> String?
  func connectionCommitted(_ namespaceID: Namespace.ID) async throws
}

enum GitHubConnectionOperationState: Equatable {
  case idle
  case loadingInstallations
  case choosingInstallation(appID: Int64, [GitHubInstallationDescriptor])
  case loadingRepositories
  case choosingRepository(
    appID: Int64,
    installation: GitHubInstallationDescriptor,
    repositories: [GitHubRepositoryDescriptor]
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

  private let broker: any GitHubConnectionBrokering
  private let credentialCleanup: any GitHubCredentialCleaning

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

  func beginConnection(
    namespaceID: Namespace.ID,
    appIDText: String,
    privateKeyFileURL: URL
  ) async {
    guard let appID = Int64(appIDText), appID > 0 else {
      states[namespaceID] = .failed(GitHubConnectionSetupError.invalidAppID.localizedDescription)
      return
    }
    states[namespaceID] = .loadingInstallations
    do {
      try await credentialCleanup.setupStarted(namespaceID)
      try await broker.configureGitHubApp(
        appID: appID,
        privateKeyFileURL: privateKeyFileURL,
        namespaceID: namespaceID
      )
      let installations = try await broker.listGitHubInstallations(namespaceID: namespaceID)
      guard !installations.isEmpty else {
        throw GitHubConnectionSetupError.noInstallations
      }
      states[namespaceID] = .choosingInstallation(
        appID: appID,
        installations.sorted { $0.accountLogin.localizedCaseInsensitiveCompare($1.accountLogin) == .orderedAscending }
      )
    } catch {
      states[namespaceID] = .failed(error.localizedDescription)
    }
  }

  func chooseInstallation(
    _ installation: GitHubInstallationDescriptor,
    namespaceID: Namespace.ID
  ) async {
    guard case .choosingInstallation(let appID, let installations) = state(for: namespaceID),
      installations.contains(installation)
    else {
      states[namespaceID] = .failed(GitHubConnectionSetupError.selectionExpired.localizedDescription)
      return
    }
    do {
      try GitHubPermissionRequirements.validate(installation)
      states[namespaceID] = .loadingRepositories
      let repositories = try await broker.listGitHubRepositories(
        installationID: installation.id,
        namespaceID: namespaceID
      )
      guard !repositories.isEmpty else {
        throw GitHubConnectionSetupError.noRepositories
      }
      states[namespaceID] = .choosingRepository(
        appID: appID,
        installation: installation,
        repositories: repositories.sorted {
          $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
      )
    } catch {
      states[namespaceID] = .failed(error.localizedDescription)
    }
  }

  func connect(
    _ repository: GitHubRepositoryDescriptor,
    namespaceID: Namespace.ID,
    save: SaveConnection
  ) async throws {
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
    do {
      try await save(connection)
    } catch {
      let saveError = error
      do {
        if let warning = try await credentialCleanup.cleanup(namespaceID) {
          states[namespaceID] = .failed(
            "The connection was not saved. \(warning)"
          )
          throw GitHubConnectionSetupError.rollbackFailed
        }
      } catch let cleanupError as GitHubConnectionSetupError {
        throw cleanupError
      } catch {
        states[namespaceID] = .failed(
          "The connection was not saved, and protected credential cleanup also failed: \(error.localizedDescription)"
        )
        throw GitHubConnectionSetupError.rollbackFailed
      }
      states[namespaceID] = .failed(saveError.localizedDescription)
      throw saveError
    }
    do {
      try await credentialCleanup.connectionCommitted(namespaceID)
      states[namespaceID] = .idle
    } catch {
      states[namespaceID] = .failed(
        "The GitHub connection was saved, but cleanup bookkeeping could not finish. Symphony will reconcile it after restart: \(error.localizedDescription)"
      )
    }
  }

  func disconnect(
    namespaceID: Namespace.ID,
    remove: RemoveConnection
  ) async throws -> String? {
    states[namespaceID] = .saving
    do {
      try await credentialCleanup.setupStarted(namespaceID)
      try await remove()
    } catch {
      try? await credentialCleanup.connectionCommitted(namespaceID)
      states[namespaceID] = .failed(error.localizedDescription)
      throw error
    }

    do {
      if let warning = try await credentialCleanup.cleanup(namespaceID) {
        states[namespaceID] = .failed(warning)
        return warning
      }
      states[namespaceID] = .idle
      return nil
    } catch {
      let message = "The namespace was disconnected, but protected credential cleanup is pending: \(error.localizedDescription)"
      states[namespaceID] = .failed(message)
      return message
    }
  }

  func check(_ connection: GitHubConnection, namespaceID: Namespace.ID) async {
    states[namespaceID] = .checking
    do {
      let installations = try await broker.listGitHubInstallations(namespaceID: namespaceID)
      guard let installation = installations.first(where: { $0.id == connection.installationID }) else {
        throw GitHubConnectionSetupError.installationRevoked
      }
      try GitHubPermissionRequirements.validate(installation)
      let repositories = try await broker.listGitHubRepositories(
        installationID: installation.id,
        namespaceID: namespaceID
      )
      guard repositories.contains(where: { $0.id == connection.repositoryID }) else {
        throw GitHubConnectionSetupError.repositoryRevoked
      }
      states[namespaceID] = .verified
    } catch {
      states[namespaceID] = .failed(error.localizedDescription)
    }
  }

  func cancelSetup(namespaceID: Namespace.ID) async -> String? {
    guard state(for: namespaceID) != .idle else { return nil }
    do {
      if let warning = try await credentialCleanup.cleanup(namespaceID) {
        states[namespaceID] = .failed(warning)
        return warning
      }
      states[namespaceID] = .idle
      return nil
    } catch {
      let message = "Connection setup was cancelled, but protected credential cleanup is pending: \(error.localizedDescription)"
      states[namespaceID] = .failed(message)
      return message
    }
  }
}

enum GitHubPermissionRequirements {
  static func validate(_ installation: GitHubInstallationDescriptor) throws {
    guard !installation.isSuspended else {
      throw GitHubConnectionSetupError.installationSuspended
    }
    var missing: [String] = []
    if !allowsRead(installation.permissions["issues"]) {
      missing.append("Issues: Read-only or Read and write")
    }
    if installation.permissions["contents"] != "write" {
      missing.append("Contents: Read and write")
    }
    guard missing.isEmpty else {
      throw GitHubConnectionSetupError.missingPermissions(missing)
    }
  }

  private static func allowsRead(_ level: String?) -> Bool {
    level == "read" || level == "write"
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
    }
  }
}
