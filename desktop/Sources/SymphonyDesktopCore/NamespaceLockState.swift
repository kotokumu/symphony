import Foundation

public enum NamespaceLockState: Equatable, Sendable {
  case locked(message: String? = nil)
  case unlocking
  case unlocked
  case lockFailed(message: String)
}
