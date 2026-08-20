import AppKit
import Foundation

@MainActor
final class ApplicationTerminationCoordinator {
  typealias StopAll = () async throws -> Void
  typealias Completion = @MainActor (Result<Void, Error>) -> Void

  private let stopAll: StopAll
  private var terminationTask: Task<Void, Never>?

  init(stopAll: @escaping StopAll) {
    self.stopAll = stopAll
  }

  func requestTermination(completion: @escaping Completion) {
    guard terminationTask == nil else {
      return
    }
    terminationTask = Task { [weak self] in
      guard let self else {
        return
      }
      defer { terminationTask = nil }
      do {
        try await stopAll()
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
  }
}

@MainActor
final class SymphonyApplicationDelegate: NSObject, NSApplicationDelegate {
  private var terminationCoordinator: ApplicationTerminationCoordinator?
  private var startSleepProtection: (() throws -> Void)?

  func configure(
    startSleepProtection: @escaping () throws -> Void,
    stopAll: @escaping ApplicationTerminationCoordinator.StopAll
  ) {
    self.startSleepProtection = startSleepProtection
    terminationCoordinator = ApplicationTerminationCoordinator(stopAll: stopAll)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      try startSleepProtection?()
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let terminationCoordinator else {
      return .terminateNow
    }

    terminationCoordinator.requestTermination { result in
      switch result {
      case .success:
        sender.reply(toApplicationShouldTerminate: true)
      case .failure(let error):
        NSAlert(error: error).runModal()
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }
}
