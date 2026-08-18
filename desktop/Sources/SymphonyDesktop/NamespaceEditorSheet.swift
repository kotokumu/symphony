import SwiftUI
import SymphonyDesktopCore

typealias DesktopNamespace = SymphonyDesktopCore.Namespace

enum NamespaceEditorContext: Identifiable {
  case create
  case rename(DesktopNamespace)

  var id: String {
    switch self {
    case .create:
      "create"
    case .rename(let namespace):
      "rename-\(namespace.id.uuidString)"
    }
  }

  var title: String {
    switch self {
    case .create:
      "Create Namespace"
    case .rename:
      "Rename Namespace"
    }
  }

  var initialName: String {
    switch self {
    case .create:
      ""
    case .rename(let namespace):
      namespace.name.value
    }
  }

  var actionTitle: String {
    switch self {
    case .create:
      "Create"
    case .rename:
      "Rename"
    }
  }
}

struct NamespaceEditorSheet: View {
  let context: NamespaceEditorContext
  let save: (String) async throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var errorMessage: String?
  @State private var isSaving = false

  init(
    context: NamespaceEditorContext,
    save: @escaping (String) async throws -> Void
  ) {
    self.context = context
    self.save = save
    _name = State(initialValue: context.initialName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(context.title)
        .font(.title2.weight(.semibold))

      TextField("Namespace Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(performSave)

      if let errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.red)
          .accessibilityLabel("Error: \(errorMessage)")
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isSaving)

        Button(context.actionTitle, action: performSave)
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving)
      }
    }
    .padding(24)
    .frame(width: 420)
    .interactiveDismissDisabled(isSaving)
  }

  private func performSave() {
    guard !isSaving else {
      return
    }

    isSaving = true
    errorMessage = nil

    Task {
      do {
        try await save(name)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        isSaving = false
      }
    }
  }
}
