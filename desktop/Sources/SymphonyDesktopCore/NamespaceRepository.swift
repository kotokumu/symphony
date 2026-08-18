public protocol NamespaceRepository: Sendable {
  func load() async throws -> NamespaceCatalog
  func create(_ namespace: Namespace, saving catalog: NamespaceCatalog) async throws
  func save(_ catalog: NamespaceCatalog) async throws
  func delete(
    _ namespace: Namespace,
    saving catalog: NamespaceCatalog
  ) async throws -> NamespaceDeletionOutcome
}

public enum NamespaceDeletionOutcome: Equatable, Sendable {
  case complete
  case cleanupPending(String)
}
