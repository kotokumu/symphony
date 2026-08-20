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

  init() {
    let command = SymphonyExecutableLocator().locate()
    let supervisor = NamespaceDaemonSupervisor(
      executableURL: command?.executableURL,
      argumentPrefix: command?.argumentPrefix ?? [],
      workingDirectoryURL: command?.workingDirectoryURL
    )
    let authenticationManager = CodexAuthenticationManager(
      executor: CodexCLICommandExecutor(executableURL: CodexExecutableLocator().locate())
    )
    let terminationAuthenticationController: CodexAuthenticationController
    do {
      let repository = try FileNamespaceRepository()
      let codexAuthenticationController = CodexAuthenticationController(
        authenticator: authenticationManager,
        directoryURL: { id in
          repository.directoryURL(for: id)
        }
      )
      _daemonController = StateObject(
        wrappedValue: NamespaceDaemonController(
          supervisor: supervisor,
          directoryURL: { id in
            repository.directoryURL(for: id)
          }
        )
      )
      _controller = StateObject(
        wrappedValue: NamespaceController(
          repository: repository,
          beforeDelete: { id in
            try await supervisor.stop(namespaceID: id)
            await codexAuthenticationController.cancel(id)
          }
        )
      )
      _authenticationController = StateObject(
        wrappedValue: codexAuthenticationController
      )
      terminationAuthenticationController = codexAuthenticationController
    } catch {
      let repository = UnavailableNamespaceRepository(message: error.localizedDescription)
      let codexAuthenticationController = CodexAuthenticationController(
        authenticator: authenticationManager,
        directoryURL: { id in
          FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        }
      )
      _daemonController = StateObject(
        wrappedValue: NamespaceDaemonController(
          supervisor: supervisor,
          directoryURL: { id in
            FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
          }
        )
      )
      _controller = StateObject(wrappedValue: NamespaceController(repository: repository))
      _authenticationController = StateObject(
        wrappedValue: codexAuthenticationController
      )
      terminationAuthenticationController = codexAuthenticationController
    }

    applicationDelegate.configure {
      await terminationAuthenticationController.cancelAll()
      try await supervisor.shutdownForApplicationTermination()
    }
  }

  var body: some Scene {
    Window("Symphony", id: "main") {
      ContentView(
        controller: controller,
        daemonController: daemonController,
        authenticationController: authenticationController
      )
    }
    .defaultSize(width: 760, height: 520)
  }
}

extension NamespaceDaemonSupervisor: NamespaceDaemonSupervising {}
extension CodexAuthenticationManager: CodexAuthenticating {}

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
