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
  private let afterLoad: (NamespaceCatalog) async throws -> Void
  private let beforeDelete: (Namespace.ID) async throws -> Void
  private let afterDelete: (Namespace.ID, Bool) async -> Void
  private let cleanupAfterDelete: (Namespace.ID, Bool) async -> String?

  init(
    repository: any NamespaceRepository,
    afterLoad: @escaping (NamespaceCatalog) async throws -> Void = { _ in },
    beforeDelete: @escaping (Namespace.ID) async throws -> Void = { _ in },
    afterDelete: @escaping (Namespace.ID, Bool) async -> Void = { _, _ in },
    cleanupAfterDelete: @escaping (Namespace.ID, Bool) async -> String? = { _, _ in nil }
  ) {
    self.repository = repository
    self.afterLoad = afterLoad
    self.beforeDelete = beforeDelete
    self.afterDelete = afterDelete
    self.cleanupAfterDelete = cleanupAfterDelete
  }

  func load() async {
    loadState = .loading

    do {
      let loadedCatalog = try await repository.load()
      try await afterLoad(loadedCatalog)
      catalog = loadedCatalog
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

  func connectNamespace(_ id: Namespace.ID, to connection: GitHubConnection) async throws {
    try beginChange()
    defer { finishChange() }

    var updatedCatalog = catalog
    try updatedCatalog.connect(id, to: .github(connection))
    try await repository.save(updatedCatalog)
    catalog = updatedCatalog
  }

  func disconnectNamespacePlatform(_ id: Namespace.ID) async throws {
    try beginChange()
    defer { finishChange() }

    var updatedCatalog = catalog
    try updatedCatalog.disconnectPlatform(id)
    try await repository.save(updatedCatalog)
    catalog = updatedCatalog
  }

  func deleteNamespace(_ id: Namespace.ID) async throws -> NamespaceDeletionOutcome {
    try beginChange()
    defer { finishChange() }

    var updatedCatalog = catalog
    let namespace = try updatedCatalog.delete(id)
    try await beforeDelete(id)
    do {
      let outcome = try await repository.delete(namespace, saving: updatedCatalog)
      catalog = updatedCatalog
      await afterDelete(id, true)
      let credentialCleanupMessage = await cleanupAfterDelete(id, true)
      return Self.combining(outcome, with: credentialCleanupMessage)
    } catch {
      await afterDelete(id, false)
      _ = await cleanupAfterDelete(id, false)
      throw error
    }
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

  private static func combining(
    _ outcome: NamespaceDeletionOutcome,
    with credentialCleanupMessage: String?
  ) -> NamespaceDeletionOutcome {
    guard let credentialCleanupMessage else {
      return outcome
    }
    switch outcome {
    case .complete:
      return .cleanupPending(credentialCleanupMessage)
    case .cleanupPending(let message):
      return .cleanupPending("\(message) \(credentialCleanupMessage)")
    }
  }
}

enum NamespaceControllerError: LocalizedError {
  case changeInProgress

  var errorDescription: String? {
    "Another namespace change is still in progress. Try again when it finishes."
  }
}
