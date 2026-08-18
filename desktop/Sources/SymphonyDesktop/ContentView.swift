import SwiftUI

struct ContentView: View {
  private let content: EmptyStateContent

  init(content: EmptyStateContent = .noNamespaces) {
    self.content = content
  }

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "square.stack.3d.up")
        .font(.system(size: 48, weight: .light))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      Text(content.title)
        .font(.title2.weight(.semibold))

      Text(content.message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }
    .padding(48)
    .frame(minWidth: 640, minHeight: 420)
  }
}
