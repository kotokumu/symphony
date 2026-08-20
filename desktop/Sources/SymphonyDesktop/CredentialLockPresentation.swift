import Foundation
import SymphonyDesktopCore

struct CredentialLockPresentation: Equatable {
  enum Action: Equatable {
    case none
    case unlock(String)
    case lock(String)
  }

  enum Tone: Equatable {
    case secondary
    case success
    case error
  }

  let status: String
  let detail: String?
  let systemImage: String?
  let showsProgress: Bool
  let tone: Tone
  let action: Action

  init(state: NamespaceLockState) {
    switch state {
    case .locked(let message):
      status = "Namespace locked"
      detail = message
      systemImage = message == nil ? "lock.fill" : "exclamationmark.triangle.fill"
      showsProgress = false
      tone = message == nil ? .secondary : .error
      action = .unlock(message == nil ? "Unlock" : "Try Unlock Again")
    case .unlocking:
      status = "Unlocking namespace…"
      detail = "Approve the macOS authentication request to unlock protected credentials."
      systemImage = nil
      showsProgress = true
      tone = .secondary
      action = .none
    case .unlocked:
      status = "Namespace unlocked"
      detail = "Protected credentials are available only to the native credential broker."
      systemImage = "lock.open.fill"
      showsProgress = false
      tone = .success
      action = .lock("Lock")
    case .lockFailed(let message):
      status = "Namespace could not be locked"
      detail = message
      systemImage = "exclamationmark.triangle.fill"
      showsProgress = false
      tone = .error
      action = .lock("Try Lock Again")
    }
  }
}
