import Foundation

@MainActor
final class ApplicationSecurityShutdownCoordinator {
  typealias Operation = () async throws -> Void
  typealias Recovery = () async -> Void

  private let windowSecurity: NamespaceWindowSecurityCoordinator
  private let lockCredentials: Operation
  private let shutdownAuthentication: Operation
  private let shutdownDaemons: Operation
  private let stopSleepProtection: () -> Void
  private let resumeAuthentication: Recovery
  private let resumeCredentials: Recovery

  init(
    windowSecurity: NamespaceWindowSecurityCoordinator,
    lockCredentials: @escaping Operation,
    shutdownAuthentication: @escaping Operation,
    shutdownDaemons: @escaping Operation,
    stopSleepProtection: @escaping () -> Void,
    resumeAuthentication: @escaping Recovery,
    resumeCredentials: @escaping Recovery
  ) {
    self.windowSecurity = windowSecurity
    self.lockCredentials = lockCredentials
    self.shutdownAuthentication = shutdownAuthentication
    self.shutdownDaemons = shutdownDaemons
    self.stopSleepProtection = stopSleepProtection
    self.resumeAuthentication = resumeAuthentication
    self.resumeCredentials = resumeCredentials
  }

  func shutdown() async throws {
    await windowSecurity.waitForCurrentOperation()
    do {
      try await lockCredentials()
      try await shutdownAuthentication()
      try await shutdownDaemons()
      stopSleepProtection()
    } catch {
      await resumeAuthentication()
      await resumeCredentials()
      throw error
    }
  }
}
