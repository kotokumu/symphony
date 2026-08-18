import Foundation

public struct NamespaceCatalog: Equatable, Sendable {
  public private(set) var namespaces: [Namespace]
  public private(set) var selectedID: Namespace.ID?

  public init() {
    namespaces = []
    selectedID = nil
  }

  public init(validating namespaces: [Namespace], selectedID: Namespace.ID?) throws {
    var names: Set<String> = []

    for namespace in namespaces {
      guard names.insert(namespace.name.comparisonKey).inserted else {
        throw NamespaceCatalogError.duplicateName(namespace.name.value)
      }
    }

    if namespaces.isEmpty {
      guard selectedID == nil else {
        throw NamespaceCatalogError.invalidSelection
      }
    } else {
      guard let selectedID, namespaces.contains(where: { $0.id == selectedID }) else {
        throw NamespaceCatalogError.invalidSelection
      }
    }

    self.namespaces = namespaces
    self.selectedID = selectedID
  }

  @discardableResult
  public mutating func create(named value: String, id: Namespace.ID = UUID()) throws -> Namespace {
    let name = try NamespaceName(validating: value)
    try ensureUnique(name)

    let namespace = Namespace(id: id, name: name)
    namespaces.append(namespace)
    selectedID = namespace.id
    return namespace
  }

  public mutating func rename(_ id: Namespace.ID, to value: String) throws {
    guard let index = namespaces.firstIndex(where: { $0.id == id }) else {
      throw NamespaceCatalogError.namespaceNotFound
    }

    let name = try NamespaceName(validating: value)
    try ensureUnique(name, excluding: id)
    namespaces[index].rename(to: name)
  }

  public mutating func select(_ id: Namespace.ID) throws {
    guard namespaces.contains(where: { $0.id == id }) else {
      throw NamespaceCatalogError.namespaceNotFound
    }

    selectedID = id
  }

  @discardableResult
  public mutating func delete(_ id: Namespace.ID) throws -> Namespace {
    guard let index = namespaces.firstIndex(where: { $0.id == id }) else {
      throw NamespaceCatalogError.namespaceNotFound
    }

    let namespace = namespaces.remove(at: index)

    if selectedID == id {
      selectedID = namespaces.isEmpty ? nil : namespaces[min(index, namespaces.count - 1)].id
    }

    return namespace
  }

  public var selectedNamespace: Namespace? {
    guard let selectedID else {
      return nil
    }

    return namespaces.first(where: { $0.id == selectedID })
  }

  private func ensureUnique(_ name: NamespaceName, excluding id: Namespace.ID? = nil) throws {
    let duplicate = namespaces.contains { namespace in
      namespace.id != id && namespace.name.comparisonKey == name.comparisonKey
    }

    guard !duplicate else {
      throw NamespaceCatalogError.duplicateName(name.value)
    }
  }
}

public enum NamespaceCatalogError: LocalizedError, Equatable, Sendable {
  case duplicateName(String)
  case namespaceNotFound
  case invalidSelection

  public var errorDescription: String? {
    switch self {
    case .duplicateName(let name):
      "A namespace named “\(name)” already exists."
    case .namespaceNotFound:
      "The namespace no longer exists."
    case .invalidSelection:
      "The selected namespace no longer exists."
    }
  }
}
