import Foundation
import SwiftUI
import SymphonyDesktopCore

@main
struct SymphonyDesktopApp: App {
  @StateObject private var controller: NamespaceController

  init() {
    let repository: any NamespaceRepository
    do {
      repository = try FileNamespaceRepository()
    } catch {
      repository = UnavailableNamespaceRepository(message: error.localizedDescription)
    }
    _controller = StateObject(wrappedValue: NamespaceController(repository: repository))
  }

  var body: some Scene {
    WindowGroup("Symphony") {
      ContentView(controller: controller)
    }
    .defaultSize(width: 760, height: 520)
  }
}

private actor UnavailableNamespaceRepository: NamespaceRepository {
  let message: String

  init(message: String) {
    self.message = message
  }

  func load() throws -> NamespaceCatalog {
    throw UnavailableNamespaceRepositoryError(message: message)
  }

  func save(_ catalog: NamespaceCatalog) throws {
    throw UnavailableNamespaceRepositoryError(message: message)
  }

  func reserveDirectory(for id: UUID) throws -> URL {
    throw UnavailableNamespaceRepositoryError(message: message)
  }

  func removeDirectory(for id: UUID) throws {
    throw UnavailableNamespaceRepositoryError(message: message)
  }

}

private struct UnavailableNamespaceRepositoryError: LocalizedError {
  let message: String

  var errorDescription: String? {
    message
  }
}
