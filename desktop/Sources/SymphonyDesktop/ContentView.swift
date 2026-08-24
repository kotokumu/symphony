import SwiftUI
import AppKit
import SymphonyDesktopCore
import SymphonyDesktopInfrastructure

struct ContentView: View {
  @ObservedObject var controller: NamespaceController
  @ObservedObject var daemonController: NamespaceDaemonController
  @ObservedObject var authenticationController: CodexAuthenticationController
  @ObservedObject var lockController: NamespaceLockController
  @ObservedObject var githubConnectionController: GitHubConnectionController
  @ObservedObject var windowSecurityCoordinator: NamespaceWindowSecurityCoordinator

  @State private var editor: NamespaceEditorContext?
  @State private var namespaceToDelete: DesktopNamespace?
  @State private var githubSetupNamespace: DesktopNamespace?
  @State private var notice: NamespaceNotice?

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
      if await windowSecurityCoordinator.waitUntilSafeToResumeAdmission() {
        githubConnectionController.resumeAfterSecurityOperation()
      }
      await daemonController.startObserving()
      await authenticationController.startObserving()
      if controller.loadState == .loading {
        await controller.load()
      }
    }
    .task(id: controller.catalog.selectedID) {
      guard let namespaceID = controller.catalog.selectedID else {
        return
      }
      await authenticationController.refresh(namespaceID)
    }
    .onDisappear {
      windowSecurityCoordinator.secureAfterWindowCloses()
    }
    .onChange(of: windowSecurityCoordinator.state) { state in
      if state == .idle {
        githubConnectionController.resumeAfterSecurityOperation()
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
    .sheet(item: $githubSetupNamespace) { namespace in
      GitHubConnectionSheet(
        namespace: namespace,
        controller: githubConnectionController,
        connect: { repository in
          try await githubConnectionController.connect(
            repository,
            namespaceID: namespace.id,
            save: { connection in
              try await controller.connectNamespace(namespace.id, to: connection)
            }
          )
          githubSetupNamespace = nil
        },
        cancel: {
          if let message = await githubConnectionController.cancelSetup(namespaceID: namespace.id) {
            notice = .changeFailed(message)
          }
          githubSetupNamespace = nil
        }
      )
      .interactiveDismissDisabled()
    }
    .alert(
      "Delete Namespace?",
      isPresented: deleteConfirmationIsPresented,
      presenting: namespaceToDelete
    ) { namespace in
      Button("Delete \(namespace.name.value)", role: .destructive) {
        Task {
          await reportErrors {
            let outcome = try await controller.deleteNamespace(namespace.id)
            if case .cleanupPending(let message) = outcome {
              notice = .cleanupPending(message)
            }
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { namespace in
      Text(
        "This permanently removes \(namespace.name.value) and all of its local data from this Mac. This action cannot be undone."
      )
    }
    .alert(item: $notice) { notice in
      Alert(
        title: Text(notice.title),
        message: Text(notice.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .safeAreaInset(edge: .top) {
      windowSecurityBanner
    }
  }

  @ViewBuilder
  private var windowSecurityBanner: some View {
    switch windowSecurityCoordinator.state {
    case .idle:
      EmptyView()
    case .securing:
      HStack {
        ProgressView()
        Text("Securing namespace credentials…")
      }
      .padding(8)
    case .failed(let message):
      HStack {
        Text("Window security cleanup failed: \(message)")
          .lineLimit(2)
        Spacer()
        Button("Retry") {
          windowSecurityCoordinator.retry()
        }
      }
      .padding(8)
      .background(.red.opacity(0.12))
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
          daemonState: daemonController.state(for: namespace.id),
          issueRuns: daemonController.issueRuns[namespace.id] ?? [],
          issueRunError: daemonController.issueRunErrors[namespace.id],
          authenticationState: authenticationController.state(for: namespace.id),
          lockState: lockController.state(for: namespace.id),
          githubConnectionState: githubConnectionController.state(for: namespace.id),
          start: {
            Task {
              await daemonController.start(namespace)
            }
          },
          stop: {
            Task {
              await reportErrors {
                try await daemonController.stop(namespace.id)
              }
            }
          },
          restart: {
            Task {
              await reportErrors {
                try await daemonController.restart(namespace)
              }
            }
          },
          startIssue: { identifier in
            Task {
              await reportErrors {
                try await daemonController.startIssue(identifier, in: namespace.id)
              }
            }
          },
          stopIssue: { identifier in
            Task {
              await reportErrors {
                try await daemonController.stopIssue(identifier, in: namespace.id)
              }
            }
          },
          retryIssue: { identifier in
            Task {
              await reportErrors {
                try await daemonController.retryIssue(identifier, in: namespace.id)
              }
            }
          },
          signIn: {
            Task {
              await authenticationController.signIn(namespace.id)
            }
          },
          signOut: {
            Task {
              await authenticationController.signOut(namespace.id)
            }
          },
          unlock: {
            Task {
              await lockController.unlock(namespace.id)
            }
          },
          lock: {
            Task {
              await reportErrors {
                try await lockController.lock(namespace.id)
              }
            }
          },
          connectGitHub: {
            githubSetupNamespace = namespace
          },
          checkGitHub: {
            guard case .github(let connection) = namespace.platformConnection else { return }
            Task {
              await githubConnectionController.check(connection, namespaceID: namespace.id)
            }
          },
          disconnectGitHub: {
            Task {
              await reportErrors {
                let warning = try await githubConnectionController.disconnect(
                  namespaceID: namespace.id,
                  remove: {
                    try await controller.disconnectNamespacePlatform(namespace.id)
                  }
                )
                if let warning {
                  notice = .cleanupPending(warning)
                }
              }
            }
          },
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
    .disabled(controller.isChanging || windowSecurityCoordinator.state == .securing)
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
      notice = .changeFailed(error.localizedDescription)
    }
  }
}

private enum NamespaceNotice: Identifiable {
  case changeFailed(String)
  case cleanupPending(String)

  var id: String {
    "\(title)-\(message)"
  }

  var title: String {
    switch self {
    case .changeFailed:
      "Namespace Change Failed"
    case .cleanupPending:
      "Cleanup Pending"
    }
  }

  var message: String {
    switch self {
    case .changeFailed(let message), .cleanupPending(let message):
      message
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
  let daemonState: NamespaceDaemonState
  let issueRuns: [NamespaceIssueRun]
  let issueRunError: String?
  let authenticationState: CodexAuthenticationState
  let lockState: NamespaceLockState
  let githubConnectionState: GitHubConnectionOperationState
  let start: () -> Void
  let stop: () -> Void
  let restart: () -> Void
  let startIssue: (String) -> Void
  let stopIssue: (String) -> Void
  let retryIssue: (String) -> Void
  let signIn: () -> Void
  let signOut: () -> Void
  let unlock: () -> Void
  let lock: () -> Void
  let connectGitHub: () -> Void
  let checkGitHub: () -> Void
  let disconnectGitHub: () -> Void
  let rename: () -> Void
  let delete: () -> Void

  @State private var issueIdentifier = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Image(systemName: "square.stack.3d.up.fill")
          .font(.system(size: 48, weight: .light))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)

        Text(namespace.name.value)
          .font(.title2.weight(.semibold))

        daemonStatus

        daemonControls

        issueOrchestration

        Divider()
          .frame(maxWidth: 440)

        credentialLockStatus

        credentialLockControls

        Divider()
          .frame(maxWidth: 440)

        githubConnectionStatus

        githubConnectionControls

        Divider()
          .frame(maxWidth: 440)

        authenticationStatus

        authenticationControls

        HStack {
          Button("Rename…", action: rename)
          Button("Delete…", role: .destructive, action: delete)
        }
      }
      .padding(48)
      .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private var githubConnectionStatus: some View {
    if case .github(let connection) = namespace.platformConnection {
      VStack(spacing: 6) {
        Label("GitHub connected", systemImage: "link.circle.fill")
          .foregroundStyle(.green)
        Text(connection.repositoryFullName)
          .font(.body.monospaced())
        Text("Installation for \(connection.accountLogin)")
          .foregroundStyle(.secondary)
      }
    } else {
      Label("GitHub not connected", systemImage: "link.badge.plus")
        .foregroundStyle(.secondary)
    }

    switch githubConnectionState {
    case .checking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Checking GitHub access…")
      }
      .foregroundStyle(.secondary)
    case .verified:
      Text("GitHub access verified")
        .foregroundStyle(.green)
    case .failed(let message):
      Text(message)
        .foregroundStyle(.red)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private var githubConnectionControls: some View {
    if namespace.platformConnection == nil {
      Button("Connect GitHub App…", action: connectGitHub)
        .disabled(lockState != .unlocked)
    } else {
      HStack {
        Button("Check Connection", action: checkGitHub)
          .disabled(lockState != .unlocked || githubConnectionState == .checking)
        Button("Disconnect", role: .destructive, action: disconnectGitHub)
      }
    }
  }

  @ViewBuilder
  private var credentialLockStatus: some View {
    let presentation = CredentialLockPresentation(state: lockState)
    if presentation.showsProgress {
      VStack(spacing: 6) {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(presentation.status)
        }
        if let detail = presentation.detail {
          Text(detail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
        }
      }
      .foregroundStyle(.secondary)
    } else if let systemImage = presentation.systemImage {
      VStack(spacing: 6) {
        Label(presentation.status, systemImage: systemImage)
          .foregroundStyle(credentialLockStatusColor(presentation.tone))
        if let detail = presentation.detail {
          Text(detail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
        }
      }
    }
  }

  @ViewBuilder
  private var credentialLockControls: some View {
    switch CredentialLockPresentation(state: lockState).action {
    case .none:
      EmptyView()
    case .unlock(let title):
      Button(title, action: unlock)
        .buttonStyle(.borderedProminent)
    case .lock(let title):
      Button(title, action: lock)
    }
  }

  private func credentialLockStatusColor(_ tone: CredentialLockPresentation.Tone) -> Color {
    switch tone {
    case .secondary:
      .secondary
    case .success:
      .green
    case .error:
      .red
    }
  }

  @ViewBuilder
  private var authenticationStatus: some View {
    let presentation = CodexAuthenticationPresentation(state: authenticationState)
    if presentation.showsProgress {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text(presentation.status)
      }
      .foregroundStyle(.secondary)
    } else if let systemImage = presentation.systemImage {
      VStack(spacing: 6) {
        Label(presentation.status, systemImage: systemImage)
          .foregroundStyle(authenticationStatusColor(presentation.tone))
        if let detail = presentation.detail {
          Text(detail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
        }
      }
    }
  }

  @ViewBuilder
  private var authenticationControls: some View {
    switch CodexAuthenticationPresentation(state: authenticationState).action {
    case .none:
      EmptyView()
    case .signIn(let title):
      Button(title, action: signIn)
        .buttonStyle(.borderedProminent)
    case .signOut(let title):
      Button(title, action: signOut)
    }
  }

  private func authenticationStatusColor(
    _ tone: CodexAuthenticationPresentation.Tone
  ) -> Color {
    switch tone {
    case .secondary:
      .secondary
    case .success:
      .green
    case .warning:
      .orange
    case .error:
      .red
    }
  }

  private var issueOrchestration: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("GitHub issue runs")
        .font(.headline)
      if let issueRunError {
        Label(issueRunError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        TextField("Issue identifier", text: $issueIdentifier)
          .textFieldStyle(.roundedBorder)
        Button("Start") {
          let identifier = issueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !identifier.isEmpty else { return }
          startIssue(identifier)
          issueIdentifier = ""
        }
        .disabled(!isDaemonRunning || issueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      if issueRuns.isEmpty {
        Text("No active, retrying, or blocked issues.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(issueRuns) { run in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(run.issueIdentifier).font(.body.monospaced())
              Text(run.status.capitalized)
                .font(.caption)
                .foregroundStyle(run.status == "blocked" ? .orange : .secondary)
              if let error = run.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
              }
            }
            Spacer()
            if run.status == "running" {
              Button("Stop") { stopIssue(run.issueIdentifier) }
            } else if run.status == "blocked" || run.status == "retrying" {
              Button("Retry") { retryIssue(run.issueIdentifier) }
            }
          }
          .padding(8)
          .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
    .frame(maxWidth: 440)
  }

  private var isDaemonRunning: Bool {
    if case .running = daemonState { return true }
    return false
  }

  @ViewBuilder
  private var daemonStatus: some View {
    switch daemonState {
    case .stopped:
      Label("Daemon stopped", systemImage: "stop.circle")
        .foregroundStyle(.secondary)
    case .starting:
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Daemon starting…")
      }
      .foregroundStyle(.secondary)
    case .running(let endpoint):
      VStack(spacing: 4) {
        Label("Daemon running", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text(endpoint.absoluteString)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    case .failed(let message):
      VStack(spacing: 6) {
        Label("Daemon failed", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
        Text(message)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 440)
      }
    }
  }

  @ViewBuilder
  private var daemonControls: some View {
    switch daemonState {
    case .stopped:
      Button("Start Daemon", action: start)
        .buttonStyle(.borderedProminent)
    case .starting:
      Button("Stop Daemon", action: stop)
    case .running:
      HStack {
        Button("Stop Daemon", action: stop)
        Button("Restart Daemon", action: restart)
      }
    case .failed:
      Button("Restart Daemon", action: restart)
        .buttonStyle(.borderedProminent)
    }
  }
}

private struct GitHubConnectionSheet: View {
  let namespace: DesktopNamespace
  @ObservedObject var controller: GitHubConnectionController
  let connect: (GitHubRepository) async throws -> Void
  let cancel: () async -> Void

  @State private var appID = ""
  @State private var privateKeyFileURL: URL?
  @State private var selectedInstallationID: Int64?
  @State private var selectedRepositoryID: Int64?
  @State private var localError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Connect GitHub App")
        .font(.title2.weight(.semibold))
      Text("Configure a GitHub App for \(namespace.name.value), then choose one installation and one repository.")
        .foregroundStyle(.secondary)

      setupContent

      if let localError {
        Text(localError)
          .foregroundStyle(.red)
      }

      HStack {
        Button("Cancel") {
          Task { await cancel() }
        }
        .disabled(controller.state(for: namespace.id) == .saving)
        Spacer()
        primaryAction
      }
    }
    .padding(24)
    .frame(width: 560)
    .frame(minHeight: 330)
  }

  @ViewBuilder
  private var setupContent: some View {
    switch controller.state(for: namespace.id) {
    case .idle, .failed:
      Form {
        TextField("GitHub App ID", text: $appID)
        HStack {
          Text(privateKeyFileURL?.lastPathComponent ?? "No private key selected")
            .foregroundStyle(privateKeyFileURL == nil ? .secondary : .primary)
          Spacer()
          Button("Choose Private Key…", action: choosePrivateKey)
        }
      }
      if case .failed(let message) = controller.state(for: namespace.id) {
        Text(message)
          .foregroundStyle(.red)
      }
    case .loadingInstallations:
      progress("Authenticating the GitHub App…")
    case .choosingInstallation(_, let installations):
      Picker("Installation", selection: $selectedInstallationID) {
        Text("Choose an installation").tag(Int64?.none)
        ForEach(installations) { installation in
          Text("\(installation.accountLogin) (\(installation.accountType))")
            .tag(Optional(installation.id))
        }
      }
    case .loadingRepositories:
      progress("Loading accessible repositories…")
    case .choosingRepository(_, let installation, let repositories):
      VStack(alignment: .leading, spacing: 12) {
        Text("Installation: \(installation.accountLogin)")
          .foregroundStyle(.secondary)
        Picker("Repository", selection: $selectedRepositoryID) {
          Text("Choose a repository").tag(Int64?.none)
          ForEach(repositories) { repository in
            Text(repository.fullName).tag(Optional(repository.id))
          }
        }
      }
    case .saving:
      progress("Saving the GitHub connection…")
    case .checking, .verified:
      EmptyView()
    }
  }

  @ViewBuilder
  private var primaryAction: some View {
    switch controller.state(for: namespace.id) {
    case .idle, .failed:
      Button("Load Installations") {
        guard let privateKeyFileURL else { return }
        Task {
          await controller.beginConnection(
            namespaceID: namespace.id,
            appIDText: appID,
            privateKeyFileURL: privateKeyFileURL
          )
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(appID.isEmpty || privateKeyFileURL == nil)
    case .choosingInstallation(_, let installations):
      Button("Load Repositories") {
        guard let selectedInstallationID,
          let installation = installations.first(where: { $0.id == selectedInstallationID })
        else { return }
        Task {
          await controller.chooseInstallation(installation, namespaceID: namespace.id)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(selectedInstallationID == nil)
    case .choosingRepository(_, _, let repositories):
      Button("Connect") {
        guard let selectedRepositoryID,
          let repository = repositories.first(where: { $0.id == selectedRepositoryID })
        else { return }
        Task {
          do {
            try await connect(repository)
          } catch {
            localError = error.localizedDescription
          }
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(selectedRepositoryID == nil)
    default:
      EmptyView()
    }
  }

  private func progress(_ title: String) -> some View {
    HStack(spacing: 10) {
      ProgressView()
      Text(title)
    }
    .frame(maxWidth: .infinity, minHeight: 100)
  }

  private func choosePrivateKey() {
    let panel = NSOpenPanel()
    panel.title = "Choose GitHub App Private Key"
    panel.prompt = "Choose"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    if panel.runModal() == .OK {
      privateKeyFileURL = panel.url
    }
  }
}
