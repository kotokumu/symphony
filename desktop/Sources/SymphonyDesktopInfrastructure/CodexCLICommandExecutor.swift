import Darwin
import Foundation

public actor CodexCLICommandExecutor: CodexCommandExecuting {
  private let executableURL: URL?
  private let fileManager: FileManager
  private let environment: [String: String]

  public init(
    executableURL: URL?,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.executableURL = executableURL
    self.fileManager = fileManager
    self.environment = environment
  }

  public func execute(_ invocation: CodexCommandInvocation) async throws -> CodexCommandResult {
    try Task.checkCancellation()
    let executableURL = try requireExecutable()
    try prepareCodexHome(invocation.codexHome)

    let process = Process()
    let output = Pipe()
    process.executableURL = executableURL
    process.arguments = invocation.arguments
    var commandEnvironment = environment
    for credentialName in ["OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_API_KEY"] {
      commandEnvironment.removeValue(forKey: credentialName)
    }
    commandEnvironment["CODEX_HOME"] = invocation.codexHome.path
    process.environment = commandEnvironment
    process.standardOutput = output
    process.standardError = output

    do {
      try process.run()
    } catch {
      throw CodexCLIError.launchFailed
    }

    return try await withTaskCancellationHandler {
      async let outputData = Task.detached {
        output.fileHandleForReading.readDataToEndOfFile()
      }.value
      let status = await Task.detached {
        process.waitUntilExit()
        return process.terminationStatus
      }.value
      let data = await outputData
      try Task.checkCancellation()
      return CodexCommandResult(
        status: status,
        output: String(decoding: data, as: UTF8.self)
      )
    } onCancel: {
      if process.isRunning {
        process.terminate()
        let processIdentifier = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
          if process.isRunning {
            Darwin.kill(processIdentifier, SIGKILL)
          }
        }
      }
    }
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
