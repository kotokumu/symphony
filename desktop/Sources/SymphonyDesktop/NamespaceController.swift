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
  private let beforeDelete: (Namespace.ID) async throws -> Void

  init(
    repository: any NamespaceRepository,
    beforeDelete: @escaping (Namespace.ID) async throws -> Void = { _ in }
  ) {
    self.repository = repository
    self.beforeDelete = beforeDelete
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
    try await repository.create(namespace, saving: updatedCatalog)
    catalog = updatedCatalog
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

  func deleteNamespace(_ id: Namespace.ID) async throws -> NamespaceDeletionOutcome {
    try beginChange()
    defer { finishChange() }

    var updatedCatalog = catalog
    let namespace = try updatedCatalog.delete(id)
    try await beforeDelete(id)
    let outcome = try await repository.delete(namespace, saving: updatedCatalog)
    catalog = updatedCatalog
    return outcome
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
