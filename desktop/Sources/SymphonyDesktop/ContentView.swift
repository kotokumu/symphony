import SwiftUI
import SymphonyDesktopCore

struct ContentView: View {
  @ObservedObject var controller: NamespaceController

  @State private var editor: NamespaceEditorContext?
  @State private var namespaceToDelete: DesktopNamespace?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      switch controller.loadState {
      case .loading:
        ProgressView("Loading namespaces…")
          .frame(minWidth: 640, minHeight: 420)
      case .failed(let message):
        loadFailure(message)
      case .ready:
        namespaceBrowser
      }
    }
    .task {
      if controller.loadState == .loading {
        await controller.load()
      }
    }
    .sheet(item: $editor) { context in
      NamespaceEditorSheet(context: context) { name in
        switch context {
        case .create:
          try await controller.createNamespace(named: name)
        case .rename(let namespace):
          try await controller.renameNamespace(namespace.id, to: name)
        }
      }
    }
    .alert(
      "Delete Namespace?",
      isPresented: deleteConfirmationIsPresented,
      presenting: namespaceToDelete
    ) { namespace in
      Button("Delete \(namespace.name.value)", role: .destructive) {
        Task {
          await reportErrors {
            try await controller.deleteNamespace(namespace.id)
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { namespace in
      Text(
        "This permanently removes \(namespace.name.value) and all of its local data from this Mac. This action cannot be undone."
      )
    }
    .alert("Namespace Change Failed", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "The namespace change could not be completed.")
    }
  }

  private var namespaceBrowser: some View {
    NavigationSplitView {
      List(selection: selectedNamespaceID) {
        ForEach(controller.catalog.namespaces) { namespace in
          Text(namespace.name.value)
            .tag(namespace.id)
            .contextMenu {
              Button("Rename…") {
                editor = .rename(namespace)
              }
              Divider()
              Button("Delete…", role: .destructive) {
                namespaceToDelete = namespace
              }
            }
        }
      }
      .navigationTitle("Namespaces")
      .toolbar {
        ToolbarItem {
          Button {
            editor = .create
          } label: {
            Label("New Namespace", systemImage: "plus")
          }
          .keyboardShortcut("n", modifiers: .command)
        }
      }
    } detail: {
      if let namespace = controller.catalog.selectedNamespace {
        NamespaceDetailView(
          namespace: namespace,
          rename: { editor = .rename(namespace) },
          delete: { namespaceToDelete = namespace }
        )
      } else {
        EmptyNamespaceView {
          editor = .create
        }
      }
    }
    .frame(minWidth: 760, minHeight: 520)
    .disabled(controller.isChanging)
  }

  private var selectedNamespaceID: Binding<DesktopNamespace.ID?> {
    Binding(
      get: { controller.catalog.selectedID },
      set: { id in
        guard let id, id != controller.catalog.selectedID else {
          return
        }

        Task {
          await reportErrors {
            try await controller.selectNamespace(id)
          }
        }
      }
    )
  }

  private var deleteConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { namespaceToDelete != nil },
      set: { isPresented in
        if !isPresented {
          namespaceToDelete = nil
        }
      }
    )
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { isPresented in
        if !isPresented {
          errorMessage = nil
        }
      }
    )
  }

  private func loadFailure(_ message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 44, weight: .light))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Namespaces Could Not Be Loaded")
        .font(.title2.weight(.semibold))
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      Button("Try Again") {
        Task {
          await controller.load()
        }
      }
    }
    .frame(minWidth: 640, minHeight: 420)
  }

  private func reportErrors(_ operation: () async throws -> Void) async {
    do {
      try await operation()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct EmptyNamespaceView: View {
  let create: () -> Void

  var body: some View {
    let content = EmptyStateContent.noNamespaces

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
      Button("Create Namespace", action: create)
        .buttonStyle(.borderedProminent)
    }
  }
}

private struct NamespaceDetailView: View {
  let namespace: DesktopNamespace
  let rename: () -> Void
  let delete: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "square.stack.3d.up.fill")
        .font(.system(size: 48, weight: .light))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      Text(namespace.name.value)
        .font(.title2.weight(.semibold))

      Text("This namespace is ready for a platform connection.")
        .foregroundStyle(.secondary)

      HStack {
        Button("Rename…", action: rename)
        Button("Delete…", role: .destructive, action: delete)
      }
    }
    .padding(48)
  }
}
