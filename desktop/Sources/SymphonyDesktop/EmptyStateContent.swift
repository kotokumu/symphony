struct EmptyStateContent: Equatable, Sendable {
  let title: String
  let message: String

  static let noNamespaces = EmptyStateContent(
    title: "No Namespaces",
    message: "Create a namespace to start orchestrating work with Symphony."
  )
}
