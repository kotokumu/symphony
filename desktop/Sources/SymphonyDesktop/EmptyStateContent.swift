struct EmptyStateContent: Equatable, Sendable {
  let title: String
  let message: String

  static let namespaces = EmptyStateContent(
    title: "No Namespaces",
    message: "Create a namespace to start orchestrating work with Symphony."
  )
}
