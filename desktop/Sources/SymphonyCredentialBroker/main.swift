import Darwin
import Foundation
import SymphonyCredentialBrokerKit
import SymphonyCredentialBrokerProtocol

@main
struct SymphonyCredentialBrokerMain {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 2, arguments[0] == "git-credential" {
      Foundation.exit(BrokerGitCredentialHelper.run(action: arguments[1]))
    }
    if arguments.count >= 2, arguments[0] == "git-runner" {
      Foundation.exit(runGitProcess(executable: arguments[1], arguments: Array(arguments.dropFirst(2))))
    }
    if arguments == ["git-watchdog"] {
      let gitProcessID = getppid()
      guard gitProcessID > 1, getpgid(gitProcessID) == gitProcessID,
        parentExecutableMatchesBroker(gitProcessID)
      else { Foundation.exit(77) }
      var ready: UInt8 = 1
      guard Darwin.write(STDOUT_FILENO, &ready, 1) == 1 else { Foundation.exit(77) }
      Darwin.close(STDOUT_FILENO)
      monitorBrokerLifetime(descriptor: STDIN_FILENO, gitProcessID: gitProcessID)
    }
    guard arguments.count == 2, let namespaceID = UUID(uuidString: arguments[1]) else {
      FileHandle.standardError.write(Data("Invalid broker invocation.\n".utf8))
      Foundation.exit(64)
    }

    do {
      try ParentCodeSignatureBrokerClientAuthorizer().authorizeCaller()
    } catch {
      if arguments[0] == "serve" {
        write(CredentialBrokerHandshake.failed(message: error.localizedDescription))
      }
      Foundation.exit(77)
    }

    let session = NamespaceCredentialSession(namespaceID: namespaceID)
    switch arguments[0] {
    case "serve":
      do {
        try await session.unlock(
          reason: "Unlock protected credentials for this Symphony namespace."
        )
        write(CredentialBrokerHandshake.unlocked)
        let signalShutdown = BrokerSignalShutdown {
          try await session.lock()
        }
        defer { signalShutdown.cancel() }
        try await serve(session)
      } catch {
        write(CredentialBrokerHandshake.failed(message: error.localizedDescription))
        Foundation.exit(1)
      }
    case "purge":
      do {
        try await session.removeStoredCredential()
      } catch {
        FileHandle.standardError.write(Data("Protected credential cleanup failed.\n".utf8))
        Foundation.exit(1)
      }
    default:
      FileHandle.standardError.write(Data("Unknown broker operation.\n".utf8))
      Foundation.exit(64)
    }
  }

  private static func runGitProcess(executable: String, arguments: [String]) -> Int32 {
    guard Darwin.setpgid(0, 0) == 0 else { return 1 }
    let authorityDescriptor: Int32 = 4
    guard let authorityValue = getenv("SYMPHONY_GIT_AUTHORITY_FD"),
      let authoritySource = Int32(String(cString: authorityValue)),
      authoritySource >= 0
    else { return 1 }
    var authorityInformation = stat()
    guard Darwin.fstat(authoritySource, &authorityInformation) == 0,
      authorityInformation.st_mode & S_IFMT == S_IFDIR,
      (authoritySource == authorityDescriptor
        || Darwin.dup2(authoritySource, authorityDescriptor) == authorityDescriptor)
    else { return 1 }
    unsetenv("SYMPHONY_GIT_AUTHORITY_FD")
    var authorityFlags = Darwin.fcntl(authorityDescriptor, F_GETFD)
    guard authorityFlags >= 0 else { return 1 }
    authorityFlags &= ~FD_CLOEXEC
    guard Darwin.fcntl(authorityDescriptor, F_SETFD, authorityFlags) == 0,
      Darwin.dup2(STDOUT_FILENO, STDERR_FILENO) == STDERR_FILENO,
      Darwin.fchdir(authorityDescriptor) == 0
    else { return 1 }
    let credentialDescriptor: Int32 = 3
    guard Darwin.dup2(STDIN_FILENO, credentialDescriptor) == credentialDescriptor else { return 1 }
    var descriptorFlags = Darwin.fcntl(credentialDescriptor, F_GETFD)
    guard descriptorFlags >= 0 else { return 1 }
    descriptorFlags &= ~FD_CLOEXEC
    guard Darwin.fcntl(credentialDescriptor, F_SETFD, descriptorFlags) == 0 else { return 1 }
    let nullDescriptor = Darwin.open("/dev/null", O_RDONLY)
    guard nullDescriptor >= 0 else { return 1 }
    defer { Darwin.close(nullDescriptor) }
    guard Darwin.dup2(nullDescriptor, STDIN_FILENO) == STDIN_FILENO else { return 1 }
    guard setenv("SYMPHONY_GIT_HELPER_FD", String(credentialDescriptor), 1) == 0 else { return 1 }

    let watchdog = Process()
    let readiness = Pipe()
    watchdog.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    watchdog.arguments = ["git-watchdog"]
    watchdog.standardInput = FileHandle(fileDescriptor: credentialDescriptor, closeOnDealloc: false)
    watchdog.standardOutput = readiness
    watchdog.standardError = FileHandle.nullDevice
    do {
      try watchdog.run()
    } catch {
      return 1
    }
    readiness.fileHandleForWriting.closeFile()
    guard waitForWatchdogReadiness(readiness.fileHandleForReading.fileDescriptor) else {
      watchdog.terminate()
      return 1
    }
    readiness.fileHandleForReading.closeFile()

    var pointers: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
    guard pointers.allSatisfy({ $0 != nil }) else { return 1 }
    defer { pointers.compactMap { $0 }.forEach { free($0) } }
    pointers.append(nil)
    executable.withCString { path in
      _ = Darwin.execv(path, &pointers)
    }
    return 1
  }

  private static func waitForWatchdogReadiness(_ descriptor: Int32) -> Bool {
    var polled = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
    guard Darwin.poll(&polled, 1, 1_000) > 0 else { return false }
    var byte: UInt8 = 0
    return Darwin.read(descriptor, &byte, 1) == 1 && byte == 1
  }

  private static func monitorBrokerLifetime(descriptor: Int32, gitProcessID: Int32) -> Never {
    while true {
      var polled = pollfd(
        fd: descriptor,
        events: Int16(POLLHUP | POLLERR | POLLNVAL),
        revents: 0
      )
      let result = Darwin.poll(&polled, 1, 50)
      if result > 0, polled.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
        _ = Darwin.kill(-gitProcessID, SIGKILL)
        Darwin._exit(1)
      }
      if getppid() != gitProcessID {
        Darwin._exit(0)
      }
    }
  }

  private static func parentExecutableMatchesBroker(_ processID: Int32) -> Bool {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(processID, &path, UInt32(path.count)) > 0 else { return false }
    return URL(fileURLWithPath: String(cString: path)).standardizedFileURL
      == URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
  }

  private static func serve(_ session: NamespaceCredentialSession) async throws {
    while let data = try BrokerStandardInput.readLine(maximumBytes: 65_536) {
      do {
        let command = try JSONDecoder().decode(CredentialBrokerCommand.self, from: data)
        try command.validatePayloadShape()
        switch command.operation {
        case .signChallenge:
          guard let challenge = command.payload else {
            throw BrokerCommandError.missingPayload
          }
          write(CredentialBrokerResult.signature(try await session.signChallenge(challenge)))
        case .configureGitHubApp:
          guard let configuration = command.githubAppConfiguration else {
            throw BrokerCommandError.missingPayload
          }
          try await session.configureGitHubApp(
            appID: configuration.appID,
            privateKeyFilePath: configuration.privateKeyFilePath
          )
          write(CredentialBrokerResult.githubAppConfigured)
        case .listGitHubInstallations:
          write(
            CredentialBrokerResult.githubInstallations(
              try await session.listGitHubInstallations()
            )
          )
        case .listGitHubRepositories:
          guard let installationID = command.installationID else {
            throw BrokerCommandError.missingPayload
          }
          write(
            CredentialBrokerResult.githubRepositories(
              try await session.listGitHubRepositories(installationID: installationID)
            )
          )
        case .authorizeGitHubRepository:
          guard let authorization = command.githubRepositoryAuthorization else {
            throw BrokerCommandError.missingPayload
          }
          try await session.authorizeGitHubRepository(authorization)
          write(CredentialBrokerResult.githubRepositoryAuthorized)
        case .performGitHubIssueRequest:
          guard let request = command.githubIssueRequest else {
            throw BrokerCommandError.missingPayload
          }
          write(
            CredentialBrokerResult.githubIssueResponse(
              try await session.performGitHubIssueRequest(request)
            )
          )
        case .githubInstallationToken:
          write(
            CredentialBrokerResult.githubInstallationToken(
              try await session.githubInstallationToken()
            )
          )
        case .performGitHubGitOperation:
          guard let request = command.githubGitRequest else {
            throw BrokerCommandError.missingPayload
          }
          write(
            CredentialBrokerResult.githubGitResult(
              try await session.performGitHubGitOperation(request)
            )
          )
        case .lock:
          try await session.lock()
          write(CredentialBrokerResult.locked)
          return
        }
      } catch let error as GitHubRepositoryAPIError {
        write(CredentialBrokerResult.githubCapabilityFailed(error.failure))
      } catch let error as GitHubRepositoryAccessError {
        write(CredentialBrokerResult.githubCapabilityFailed(error.failure))
      } catch {
        write(CredentialBrokerResult.failed(message: error.localizedDescription))
      }
    }
    try await session.lock()
  }

  private static func write<Value: Encodable>(_ value: Value) {
    do {
      var data = try JSONEncoder().encode(value)
      if data.count > CredentialBrokerProtocolLimits.maximumResponseBytes {
        data = try JSONEncoder().encode(
          CredentialBrokerResult.failed(
            message: "The credential broker result exceeded the safe response limit."
          )
        )
      }
      data.append(0x0A)
      FileHandle.standardOutput.write(data)
    } catch {
      FileHandle.standardError.write(Data("Broker response failed.\n".utf8))
      Foundation.exit(1)
    }
  }
}

private final class BrokerSignalShutdown: @unchecked Sendable {
  private let term: DispatchSourceSignal
  private let interrupt: DispatchSourceSignal

  init(action: @escaping @Sendable () async throws -> Void) {
    Darwin.signal(SIGTERM, SIG_IGN)
    Darwin.signal(SIGINT, SIG_IGN)
    term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
    interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
    let handler: @Sendable () -> Void = {
      _ = Task {
        do {
          try await action()
          Foundation.exit(0)
        } catch {
          Foundation.exit(1)
        }
      }
    }
    term.setEventHandler(handler: DispatchWorkItem(block: handler))
    interrupt.setEventHandler(handler: DispatchWorkItem(block: handler))
    term.resume()
    interrupt.resume()
  }

  func cancel() {
    term.cancel()
    interrupt.cancel()
  }
}

private enum BrokerStandardInput {
  static func readLine(maximumBytes: Int) throws -> Data? {
    var line = Data()
    while line.count <= maximumBytes {
      guard let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty else {
        return line.isEmpty ? nil : line
      }
      if byte[byte.startIndex] == 0x0A {
        return line
      }
      line.append(byte)
    }
    throw BrokerCommandError.messageTooLarge
  }
}

private enum BrokerCommandError: LocalizedError {
  case missingPayload
  case messageTooLarge

  var errorDescription: String? {
    switch self {
    case .missingPayload:
      "The credential capability request is missing its payload."
    case .messageTooLarge:
      "The credential capability request is too large."
    }
  }
}
