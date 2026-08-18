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
    var updatedCatalog = catalog
    try updatedCatalog.rename(id, to: name)
    try await repository.save(updatedCatalog)
    catalog = updatedCatalog
  }

  func selectNamespace(_ id: Namespace.ID) async throws {
    var updatedCatalog = catalog
    try updatedCatalog.select(id)
    try await repository.save(updatedCatalog)
    catalog = updatedCatalog
  }

  func deleteNamespace(_ id: Namespace.ID) async throws {
    var updatedCatalog = catalog
    _ = try updatedCatalog.delete(id)
    try await repository.save(updatedCatalog)
    catalog = updatedCatalog
    try await repository.removeDirectory(for: id)
  }
}
