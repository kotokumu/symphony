import Combine
import Foundation
import SymphonyDesktopCore

enum NamespaceLoadState: Equatable {
  case loading
  case ready
  case failed(String)
}

@MainActor
final class NamespaceController: ObservableObject {
  @Published private(set) var catalog = NamespaceCatalog()
  @Published private(set) var loadState = NamespaceLoadState.loading
  @Published private(set) var isChanging = false

  private let repository: any NamespaceRepository

  init(repository: any NamespaceRepository) {
    self.repository = repository
  }

  func load() async {
    loadState = .loading

    do {
      catalog = try await repository.load()
      loadState = .ready
    } catch {
      loadState = .failed(error.localizedDescription)
    }
  }

  func createNamespace(named name: String) async throws {
    try beginChange()
    defer { finishChange() }

    var updatedCatalog = catalog
    let namespace = try updatedCatalog.create(named: name)
    var reservedDirectory = false

    do {
      _ = try await repository.reserveDirectory(for: namespace.id)
      reservedDirectory = true
      try await repository.save(updatedCatalog)
      catalog = updatedCatalog
    } catch {
      if reservedDirectory {
        try? await repository.removeDirectory(for: namespace.id)
      }
      throw error
    }
  }

  func renameNamespace(_ id: Namespace.ID, to name: String) async throws {
    try beginChange()
    defer { finishChange() }

    var updatedCatalog = catalog
    try updatedCatalog.rename(id, to: name)
    try await repository.save(updatedCatalog)
    catalog = updatedCatalog
  }

  func selectNamespace(_ id: Namespace.ID) async throws {
    try beginChange()
    defer { finishChange() }

    var updatedCatalog = catalog
    try updatedCatalog.select(id)
    try await repository.save(updatedCatalog)
    catalog = updatedCatalog
  }

  func deleteNamespace(_ id: Namespace.ID) async throws {
    try beginChange()
    defer { finishChange() }

    var updatedCatalog = catalog
    _ = try updatedCatalog.delete(id)
    try await repository.save(updatedCatalog)
    catalog = updatedCatalog
    try await repository.removeDirectory(for: id)
  }

  private func beginChange() throws {
    guard !isChanging else {
      throw NamespaceControllerError.changeInProgress
    }
    isChanging = true
  }

  private func finishChange() {
    isChanging = false
  }
}

enum NamespaceControllerError: LocalizedError {
  case changeInProgress

  var errorDescription: String? {
    "Another namespace change is still in progress. Try again when it finishes."
  }
}
