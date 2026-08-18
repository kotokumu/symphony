import Foundation

public protocol NamespaceRepository: Sendable {
  func load() async throws -> NamespaceCatalog
  func save(_ catalog: NamespaceCatalog) async throws
  func reserveDirectory(for id: Namespace.ID) async throws -> URL
  func removeDirectory(for id: Namespace.ID) async throws
}
