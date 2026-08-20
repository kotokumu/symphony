import Darwin
import Foundation

public actor CodexCLICommandExecutor: CodexCommandExecuting {
  private struct Runtime {
    let process: Process
    let outputReadHandle: FileHandle
    let outputReader: Task<Data, Never>
  }

  private let executableURL: URL?
  private let fileManager: FileManager
  private let environment: [String: String]
  private let gracefulStopTimeout: TimeInterval
  private let forcedStopTimeout: TimeInterval
  private let forceKill: @Sendable (Int32) -> Int32
  private var runtimes: [URL: Runtime] = [:]

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
    guard runtimes[invocation.codexHome] == nil else {
      throw CodexCommandLifecycleError.commandAlreadyRunning
    }

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

    let outputReadHandle = output.fileHandleForReading
    let outputReader = Task.detached {
      outputReadHandle.readDataToEndOfFile()
    }
    runtimes[invocation.codexHome] = Runtime(
      process: process,
      outputReadHandle: outputReadHandle,
      outputReader: outputReader
    )
    do {
      while process.isRunning {
        try await Task.sleep(for: .milliseconds(25))
      }
      try Task.checkCancellation()
    } catch is CancellationError {
      try await stop(codexHome: invocation.codexHome)
      throw CancellationError()
    }
    let data = await outputReader.value
    removeRuntime(for: invocation.codexHome, process: process)
    return CodexCommandResult(
      status: process.terminationStatus,
      output: String(decoding: data, as: UTF8.self)
    )
  }

  public func stop(codexHome: URL) async throws {
    guard let runtime = runtimes[codexHome] else {
      return
    }
    try await terminate(runtime.process)
    try? runtime.outputReadHandle.close()
    runtime.outputReader.cancel()
    removeRuntime(for: codexHome, process: runtime.process)
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
      throw CodexCommandLifecycleError.stopFailed
    }
    guard await waitForExit(process, timeout: forcedStopTimeout) else {
      throw CodexCommandLifecycleError.stopFailed
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

  private func removeRuntime(for codexHome: URL, process: Process) {
    guard runtimes[codexHome]?.process === process else {
      return
    }
    runtimes.removeValue(forKey: codexHome)
  }
}

public enum CodexCLIError: LocalizedError, Sendable {
  case executableNotFound
  case executableNotExecutable(URL)
  case homePreparationFailed
  case launchFailed

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
    }
  }
}
