import SymphonyDesktopCore

struct CodexAuthenticationPresentation: Equatable {
  enum Tone: Equatable {
    case secondary
    case success
    case warning
    case error
  }

  enum Action: Equatable {
    case none
    case signIn(title: String)
    case signOut(title: String)
  }

  let status: String
  let systemImage: String?
  let detail: String?
  let tone: Tone
  let showsProgress: Bool
  let action: Action

  init(state: CodexAuthenticationState) {
    switch state {
    case .signedOut:
      self.init(
        status: "Codex signed out",
        systemImage: "person.crop.circle.badge.xmark",
        detail: nil,
        tone: .secondary,
        showsProgress: false,
        action: .signIn(title: "Sign in with ChatGPT")
      )
    case .authenticating:
      self.init(
        status: "Waiting for ChatGPT sign-in…",
        systemImage: nil,
        detail: nil,
        tone: .secondary,
        showsProgress: true,
        action: .none
      )
    case .signedIn:
      self.init(
        status: "Codex signed in",
        systemImage: "person.crop.circle.badge.checkmark",
        detail: nil,
        tone: .success,
        showsProgress: false,
        action: .signOut(title: "Sign Out")
      )
    case .expired(let message):
      self.init(
        status: "Codex sign-in expired",
        systemImage: "clock.badge.exclamationmark",
        detail: message,
        tone: .warning,
        showsProgress: false,
        action: .signIn(title: "Try Sign In Again")
      )
    case .failed(let message):
      self.init(
        status: "Codex authentication failed",
        systemImage: "exclamationmark.triangle.fill",
        detail: message,
        tone: .error,
        showsProgress: false,
        action: .signIn(title: "Try Sign In Again")
      )
    }
  }

  private init(
    status: String,
    systemImage: String?,
    detail: String?,
    tone: Tone,
    showsProgress: Bool,
    action: Action
  ) {
    self.status = status
    self.systemImage = systemImage
    self.detail = detail
    self.tone = tone
    self.showsProgress = showsProgress
    self.action = action
  }
}
