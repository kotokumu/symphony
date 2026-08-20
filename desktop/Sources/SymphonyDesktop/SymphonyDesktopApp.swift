import Foundation
import SwiftUI
import SymphonyDesktopCore
import SymphonyDesktopInfrastructure

@main
struct SymphonyDesktopApp: App {
  @NSApplicationDelegateAdaptor(SymphonyApplicationDelegate.self)
  private var applicationDelegate

  @StateObject private var controller: NamespaceController
  @StateObject private var daemonController: NamespaceDaemonController
  @StateObject private var authenticationController: CodexAuthenticationController
  @StateObject private var lockController: NamespaceLockController
  @StateObject private var githubConnectionController: GitHubConnectionController
  @StateObject private var sleepLockCoordinator: NamespaceSleepLockCoordinator
  @StateObject private var windowSecurityCoordinator: NamespaceWindowSecurityCoordinator

  init() {
    let command = SymphonyExecutableLocator().locate()
    let codexExecutableURL = CodexExecutableLocator().locate()
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: command?.executableURL,
      codexExecutableURL: codexExecutableURL,
      argumentPrefix: command?.argumentPrefix ?? [],
      workingDirectoryURL: command?.workingDirectoryURL
    )
    let authenticationManager = CodexAuthenticationManager(
      executor: CodexCLICommandExecutor(executableURL: codexExecutableURL)
    )
    let credentialBroker = NamespaceCredentialBroker(
      launcher: CredentialBrokerProcessLauncher(
        executableURL: CredentialBrokerExecutableLocator().locate()
      )
    )
    let namespaceLockController = NamespaceLockController(
      broker: credentialBroker,
      sleepProtectionAvailable: false
    )
    let namespaceSleepLockCoordinator = NamespaceSleepLockCoordinator {
      try await namespaceLockController.lockAll()
    }
    _lockController = StateObject(wrappedValue: namespaceLockController)
    _sleepLockCoordinator = StateObject(wrappedValue: namespaceSleepLockCoordinator)
    let namespaceWindowSecurityCoordinator: NamespaceWindowSecurityCoordinator
    do {
      let repository = try FileNamespaceRepository()
      let credentialCleanupCoordinator = NamespaceCredentialCleanupCoordinator(
        store: try PendingCredentialCleanupStore(),
        purge: { id in
          try await namespaceLockController.removeNamespace(id)
        }
      )
      let githubCredentialCleanupCoordinator = GitHubCredentialCleanupCoordinator(
        store: try PendingCredentialCleanupStore(
          fileName: "pending-github-credential-cleanup.json"
        ),
        purge: { id in
          try await namespaceLockController.removeNamespace(id)
        }
      )
      _githubConnectionController = StateObject(
        wrappedValue: GitHubConnectionController(
          broker: credentialBroker,
          credentialCleanup: githubCredentialCleanupCoordinator
        )
      )
      let codexAuthenticationController = CodexAuthenticationController(
        authenticator: authenticationManager,
        directoryURL: { id in
          repository.directoryURL(for: id)
        }
      )
      let namespaceDaemonController = NamespaceDaemonController(
        supervisor: supervisor,
        directoryURL: { id in
          repository.directoryURL(for: id)
        },
        afterStop: { id in
          try await namespaceLockController.lock(id)
        },
        afterStopAll: {
          try await namespaceLockController.lockAll()
        }
      )
      _daemonController = StateObject(wrappedValue: namespaceDaemonController)
      _controller = StateObject(
        wrappedValue: NamespaceController(
          repository: repository,
          afterLoad: { catalog in
            try await credentialCleanupCoordinator.reconcile(
              existingNamespaceIDs: Set(catalog.namespaces.map(\.id))
            )
            try await githubCredentialCleanupCoordinator.reconcile(catalog)
          },
          beforeDelete: { id in
            try await supervisor.stop(namespaceID: id)
            try await authenticationManager.quiesce(namespaceID: id)
            do {
              try await namespaceLockController.lock(id)
              try await credentialCleanupCoordinator.stageDeletion(id)
            } catch {
              await authenticationManager.resume(namespaceID: id)
              throw error
            }
          },
          afterDelete: { id, succeeded in
            if succeeded {
              await authenticationManager.removeNamespace(id)
            } else {
              await authenticationManager.resume(namespaceID: id)
            }
          },
          cleanupAfterDelete: { id, succeeded in
            await credentialCleanupCoordinator.finishDeletion(id, committed: succeeded)
          }
        )
      )
      _authenticationController = StateObject(
        wrappedValue: codexAuthenticationController
      )
      namespaceWindowSecurityCoordinator = NamespaceWindowSecurityCoordinator(
        lockCredentials: {
          try await namespaceLockController.lockAll()
        },
        cancelAuthentication: {
          try await codexAuthenticationController.cancelAll()
        },
        stopDaemons: {
          try await namespaceDaemonController.stopAll()
        }
      )
      _windowSecurityCoordinator = StateObject(
        wrappedValue: namespaceWindowSecurityCoordinator
      )
    } catch {
      let repository = UnavailableNamespaceRepository(message: error.localizedDescription)
      let codexAuthenticationController = CodexAuthenticationController(
        authenticator: authenticationManager,
        directoryURL: { id in
          FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        }
      )
      let namespaceDaemonController = NamespaceDaemonController(
        supervisor: supervisor,
        directoryURL: { id in
          FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        },
        afterStop: { id in
          try await namespaceLockController.lock(id)
        },
        afterStopAll: {
          try await namespaceLockController.lockAll()
        }
      )
      _daemonController = StateObject(wrappedValue: namespaceDaemonController)
      _controller = StateObject(wrappedValue: NamespaceController(repository: repository))
      _authenticationController = StateObject(
        wrappedValue: codexAuthenticationController
      )
      _githubConnectionController = StateObject(
        wrappedValue: GitHubConnectionController(
          broker: credentialBroker,
          credentialCleanup: UnavailableGitHubCredentialCleanup(
            message: error.localizedDescription
          )
        )
      )
      namespaceWindowSecurityCoordinator = NamespaceWindowSecurityCoordinator(
        lockCredentials: {
          try await namespaceLockController.lockAll()
        },
        cancelAuthentication: {
          try await codexAuthenticationController.cancelAll()
        },
        stopDaemons: {
          try await namespaceDaemonController.stopAll()
        }
      )
      _windowSecurityCoordinator = StateObject(
        wrappedValue: namespaceWindowSecurityCoordinator
      )
    }

    applicationDelegate.configure(
      startSleepProtection: {
        do {
          try namespaceSleepLockCoordinator.start()
          namespaceLockController.setSleepProtectionAvailable(true)
        } catch {
          namespaceLockController.setSleepProtectionAvailable(false)
          throw error
        }
      }
    ) {
      try await ApplicationSecurityShutdownCoordinator(
        windowSecurity: namespaceWindowSecurityCoordinator,
        lockCredentials: {
          try await namespaceLockController.shutdownForApplicationTermination()
        },
        shutdownAuthentication: {
          try await authenticationManager.shutdownForApplicationTermination()
        },
        shutdownDaemons: {
          try await supervisor.shutdownForApplicationTermination()
        },
        stopSleepProtection: {
          namespaceSleepLockCoordinator.stop()
        },
        resumeAuthentication: {
          await authenticationManager.resumeAfterApplicationTerminationFailure()
        },
        resumeCredentials: {
          await namespaceLockController.resumeAfterApplicationTerminationFailure()
        }
      ).shutdown()
    }
  }

  var body: some Scene {
    Window("Symphony", id: "main") {
      ContentView(
        controller: controller,
        daemonController: daemonController,
        authenticationController: authenticationController,
        lockController: lockController,
        githubConnectionController: githubConnectionController,
        windowSecurityCoordinator: windowSecurityCoordinator
      )
    }
    .defaultSize(width: 760, height: 520)
  }
}

extension NamespaceDaemonSupervisor: NamespaceDaemonSupervising {}
extension CodexAuthenticationManager: CodexAuthenticating {}
extension NamespaceCredentialBroker: NamespaceCredentialBrokering {}
extension NamespaceCredentialBroker: GitHubConnectionBrokering {}
extension GitHubCredentialCleanupCoordinator: GitHubCredentialCleaning {}

private actor UnavailableNamespaceRepository: NamespaceRepository {
  let message: String

  init(message: String) {
    self.message = message
  }

  func load() throws -> NamespaceCatalog {
    throw UnavailableNamespaceRepositoryError(message: message)
  }

  func create(_ namespace: SymphonyDesktopCore.Namespace, saving catalog: NamespaceCatalog) throws {
    throw UnavailableNamespaceRepositoryError(message: message)
  }

  func save(_ catalog: NamespaceCatalog) throws {
    throw UnavailableNamespaceRepositoryError(message: message)
  }

  func delete(
    _ namespace: SymphonyDesktopCore.Namespace,
    saving catalog: NamespaceCatalog
  ) throws -> NamespaceDeletionOutcome {
    throw UnavailableNamespaceRepositoryError(message: message)
  }
}

private struct UnavailableNamespaceRepositoryError: LocalizedError {
  let message: String

  var errorDescription: String? {
    message
  }
}

private actor UnavailableGitHubCredentialCleanup: GitHubCredentialCleaning {
  let message: String

  init(message: String) {
    self.message = message
  }

  func setupStarted(_ namespaceID: UUID) throws {
    throw UnavailableNamespaceRepositoryError(message: message)
  }

  func cleanup(_ namespaceID: UUID) throws -> String? {
    throw UnavailableNamespaceRepositoryError(message: message)
  }

  func connectionCommitted(_ namespaceID: UUID) throws {
    throw UnavailableNamespaceRepositoryError(message: message)
  }
}
