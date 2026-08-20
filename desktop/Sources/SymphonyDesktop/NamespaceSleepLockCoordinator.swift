import Combine
import Foundation
import IOKit
import IOKit.pwr_mgt

private let canSystemSleepMessage: natural_t = 0xe000_0270
private let systemWillSleepMessage: natural_t = 0xe000_0280

protocol SystemSleepPowerChange: Sendable {
  func allow()
  func fail()
}

protocol SystemSleepEventSource: Sendable {
  func start(handler: @escaping @Sendable (any SystemSleepPowerChange) -> Void) throws
  func stop()
}

@MainActor
final class NamespaceSleepLockCoordinator: ObservableObject {
  private let eventSource: any SystemSleepEventSource
  private let lockAll: () async throws -> Void
  private var started = false

  init(
    eventSource: any SystemSleepEventSource = IOKitSystemSleepEventSource(),
    lockAll: @escaping () async throws -> Void
  ) {
    self.eventSource = eventSource
    self.lockAll = lockAll
  }

  func start() throws {
    guard !started else { return }
    try eventSource.start { [weak self] request in
      Task { @MainActor [weak self] in
        guard let self else {
          request.fail()
          return
        }
        do {
          try await self.lockAll()
          request.allow()
        } catch {
          request.fail()
        }
      }
    }
    started = true
  }

  func stop() {
    guard started else { return }
    eventSource.stop()
    started = false
  }
}

final class IOKitSystemSleepEventSource: SystemSleepEventSource, @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (any SystemSleepPowerChange) -> Void)?
  private var notificationPort: IONotificationPortRef?
  private var notifier: io_object_t = 0
  private var rootPort: io_connect_t = 0
  private var runLoopSource: CFRunLoopSource?

  func start(handler: @escaping @Sendable (any SystemSleepPowerChange) -> Void) throws {
    try lock.withLock {
      guard rootPort == 0 else { return }
      self.handler = handler
      let reference = Unmanaged.passUnretained(self).toOpaque()
      rootPort = IORegisterForSystemPower(
        reference,
        &notificationPort,
        systemPowerCallback,
        &notifier
      )
      guard rootPort != 0, let notificationPort else {
        self.handler = nil
        throw SystemSleepRegistrationError.unavailable
      }
      let source = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
      runLoopSource = source
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
  }

  func stop() {
    lock.withLock {
      if let runLoopSource {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      }
      if notifier != 0 {
        IODeregisterForSystemPower(&notifier)
      }
      if rootPort != 0 {
        IOServiceClose(rootPort)
      }
      if let notificationPort {
        IONotificationPortDestroy(notificationPort)
      }
      runLoopSource = nil
      notificationPort = nil
      notifier = 0
      rootPort = 0
      handler = nil
    }
  }

  fileprivate func receive(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
    guard
      messageType == canSystemSleepMessage || messageType == systemWillSleepMessage,
      let argument
    else {
      return
    }
    let request = IOKitSystemSleepPowerChange(
      rootPort: lock.withLock { rootPort },
      notificationID: Int(bitPattern: argument),
      canCancel: messageType == canSystemSleepMessage
    )
    let handler = lock.withLock { self.handler }
    if let handler {
      handler(request)
    } else {
      request.fail()
    }
  }
}

private func systemPowerCallback(
  reference: UnsafeMutableRawPointer?,
  service: io_service_t,
  messageType: natural_t,
  messageArgument: UnsafeMutableRawPointer?
) {
  guard let reference else { return }
  Unmanaged<IOKitSystemSleepEventSource>
    .fromOpaque(reference)
    .takeUnretainedValue()
    .receive(messageType: messageType, argument: messageArgument)
}

private final class IOKitSystemSleepPowerChange: SystemSleepPowerChange, @unchecked Sendable {
  private let lock = NSLock()
  private let rootPort: io_connect_t
  private let notificationID: Int
  private let canCancel: Bool
  private var completed = false

  init(rootPort: io_connect_t, notificationID: Int, canCancel: Bool) {
    self.rootPort = rootPort
    self.notificationID = notificationID
    self.canCancel = canCancel
  }

  func allow() {
    complete {
      IOAllowPowerChange(rootPort, notificationID)
    }
  }

  func fail() {
    complete {
      canCancel
        ? IOCancelPowerChange(rootPort, notificationID)
        : IOAllowPowerChange(rootPort, notificationID)
    }
  }

  private func complete(_ operation: () -> IOReturn) {
    lock.withLock {
      guard !completed else { return }
      completed = true
      _ = operation()
    }
  }
}

enum SystemSleepRegistrationError: LocalizedError {
  case unavailable

  var errorDescription: String? {
    "System sleep protection could not be registered."
  }
}
