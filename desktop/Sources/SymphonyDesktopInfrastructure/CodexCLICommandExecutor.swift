import Darwin
import Foundation

public actor CodexCLICommandExecutor: CodexCommandExecuting {
  private let executableURL: URL?
  private let fileManager: FileManager
  private let environment: [String: String]
  private let gracefulStopTimeout: TimeInterval
  private let forcedStopTimeout: TimeInterval
  private let forceKill: @Sendable (Int32) -> Int32

  public init(
    executableURL: URL?,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    gracefulStopTimeout: TimeInterval = 2,
    forcedStopTimeout: TimeInterval = 2,
    forceKill: @escaping @Sendable (Int32) -> Int32 = { Darwin.kill($0, SIGKILL) }
  ) {
    self.executableURL = executableURL
    self.fileManager = fileManager
    self.environment = environment
    self.gracefulStopTimeout = gracefulStopTimeout
    self.forcedStopTimeout = forcedStopTimeout
    self.forceKill = forceKill
  }

  public func execute(_ invocation: CodexCommandInvocation) async throws -> CodexCommandResult {
    try Task.checkCancellation()
    let executableURL = try requireExecutable()
    try prepareCodexHome(invocation.codexHome)

    let process = Process()
    let output = Pipe()
    process.executableURL = executableURL
    process.arguments = invocation.arguments
    process.environment = NamespaceProcessEnvironment.sanitized(
      environment,
      codexHome: invocation.codexHome
    )
    process.standardOutput = output
    process.standardError = output

    do {
      try process.run()
    } catch {
      throw CodexCLIError.launchFailed
    }

    let outputReader = Task.detached {
      output.fileHandleForReading.readDataToEndOfFile()
    }
    do {
      while process.isRunning {
        try await Task.sleep(for: .milliseconds(25))
      }
      try Task.checkCancellation()
    } catch is CancellationError {
      try await terminate(process)
      _ = await outputReader.value
      throw CancellationError()
    }
    let data = await outputReader.value
    return CodexCommandResult(
      status: process.terminationStatus,
      output: String(decoding: data, as: UTF8.self)
    )
  }

  private func requireExecutable() throws -> URL {
    guard let executableURL else {
      throw CodexCLIError.executableNotFound
    }
    guard fileManager.isExecutableFile(atPath: executableURL.path) else {
      throw CodexCLIError.executableNotExecutable(executableURL)
    }
    return executableURL
  }

  private func prepareCodexHome(_ directory: URL) throws {
    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    } catch {
      throw CodexCLIError.homePreparationFailed
    }
  }

  private func terminate(_ process: Process) async throws {
    guard process.isRunning else {
      return
    }
    process.terminate()
    if await waitForExit(process, timeout: gracefulStopTimeout) {
      return
    }
    guard forceKill(process.processIdentifier) == 0 else {
      throw CodexCLIError.stopFailed
    }
    guard await waitForExit(process, timeout: forcedStopTimeout) else {
      throw CodexCLIError.stopFailed
    }
  }

  private func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      _ = await Task.detached {
        Darwin.usleep(25_000)
      }.value
    }
    return !process.isRunning
  }
}

public enum CodexCLIError: LocalizedError, Sendable {
  case executableNotFound
  case executableNotExecutable(URL)
  case homePreparationFailed
  case launchFailed
  case stopFailed

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "The Codex CLI could not be found. Install Codex and try again."
    case .executableNotExecutable(let url):
      "The Codex CLI at \(url.path) is not executable. Reinstall Codex and try again."
    case .homePreparationFailed:
      "The namespace Codex home could not be prepared. Check disk space and permissions, then try again."
    case .launchFailed:
      "The Codex CLI could not be launched. Reinstall Codex and try again."
    case .stopFailed:
      "The Codex authentication process could not be stopped safely. Try again before deleting the namespace or quitting."
    }
  }
}
