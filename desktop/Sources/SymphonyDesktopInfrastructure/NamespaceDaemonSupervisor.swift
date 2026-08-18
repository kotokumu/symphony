import Darwin
import Foundation
import SymphonyDesktopCore

public actor NamespaceDaemonSupervisor {
  public typealias ReadinessProbe = @Sendable (URL) async -> Bool
  public typealias PortAllocator = @Sendable () throws -> UInt16
  public typealias TerminationDelivery =
    @Sendable (
      @escaping @Sendable () async -> Void
    ) -> Void
  public typealias ForceKill = @Sendable (Int32) -> Int32

  private struct Runtime {
    let generation: UUID
    let process: Process
    let endpoint: URL
    let output: FileHandle
    let errorOutput: FileHandle
  }

  private let executableURL: URL?
  private let argumentPrefix: [String]
  private let workingDirectoryURL: URL?
  private let readinessTimeout: TimeInterval
  private let readinessProbe: ReadinessProbe
  private let portAllocator: PortAllocator
  private let terminationDelivery: TerminationDelivery
  private let gracefulStopTimeout: TimeInterval
  private let forcedStopTimeout: TimeInterval
  private let forceKill: ForceKill
  private let fileManager: FileManager

  private var generations: [Namespace.ID: UUID] = [:]
  private var runtimes: [Namespace.ID: Runtime] = [:]
  private var portReservations: [Namespace.ID: (generation: UUID, port: UInt16)] = [:]
  private var intentionalTerminations: Set<UUID> = []
  private var startSuspensionCount = 0
  private var applicationTerminationRequested = false
  private var states: [Namespace.ID: NamespaceDaemonState] = [:]
  private var eventContinuations: [UUID: AsyncStream<NamespaceDaemonEvent>.Continuation] = [:]

  public init(
    executableURL: URL?,
    argumentPrefix: [String] = [],
    workingDirectoryURL: URL? = nil,
    readinessTimeout: TimeInterval = 15,
    readinessProbe: @escaping ReadinessProbe = NamespaceDaemonSupervisor.probe,
    portAllocator: @escaping PortAllocator = NamespaceDaemonSupervisor.availableLoopbackPort,
    terminationDelivery: @escaping TerminationDelivery = { operation in
      Task {
        await operation()
      }
    },
    gracefulStopTimeout: TimeInterval = 3,
    forcedStopTimeout: TimeInterval = 2,
    forceKill: @escaping ForceKill = { Darwin.kill($0, SIGKILL) },
    fileManager: FileManager = .default
  ) {
    self.executableURL = executableURL
    self.argumentPrefix = argumentPrefix
    self.workingDirectoryURL = workingDirectoryURL
    self.readinessTimeout = readinessTimeout
    self.readinessProbe = readinessProbe
    self.portAllocator = portAllocator
    self.terminationDelivery = terminationDelivery
    self.gracefulStopTimeout = gracefulStopTimeout
    self.forcedStopTimeout = forcedStopTimeout
    self.forceKill = forceKill
    self.fileManager = fileManager
  }

  public func events() -> AsyncStream<NamespaceDaemonEvent> {
    let subscriberID = UUID()
    return AsyncStream { continuation in
      eventContinuations[subscriberID] = continuation
      continuation.onTermination = { [weak self] _ in
        Task {
          await self?.removeEventContinuation(subscriberID)
        }
      }
    }
  }

  public func start(namespaceID: Namespace.ID, namespaceDirectory: URL) async {
    guard
      startSuspensionCount == 0,
      !applicationTerminationRequested,
      !isActive(namespaceID),
      runtimes[namespaceID] == nil
    else {
      return
    }

    let generation = UUID()
    generations[namespaceID] = generation
    publish(.starting, for: namespaceID)

    do {
      let executableURL = try requireExecutable()
      let layout = try prepareRuntime(in: namespaceDirectory)
      let port = try reservePort(for: namespaceID, generation: generation)
      let endpoint = URL(string: "http://127.0.0.1:\(port)")!
      let runtime = try launch(
        executableURL: executableURL,
        layout: layout,
        endpoint: endpoint,
        port: port,
        namespaceID: namespaceID,
        generation: generation
      )
      runtimes[namespaceID] = runtime

      guard await waitUntilReady(runtime, namespaceID: namespaceID) else {
        throw NamespaceDaemonError.readinessTimedOut
      }
      guard generations[namespaceID] == generation, runtime.process.isRunning else {
        return
      }

      publish(.running(endpoint: endpoint), for: namespaceID)
    } catch {
      await failCurrentAttempt(namespaceID, generation: generation, error: error)
    }
  }

  public func stop(namespaceID: Namespace.ID) async throws {
    guard let runtime = runtimes[namespaceID] else {
      generations.removeValue(forKey: namespaceID)
      releasePort(for: namespaceID)
      publish(.stopped, for: namespaceID)
      return
    }

    if intentionalTerminations.contains(runtime.generation) {
      while intentionalTerminations.contains(runtime.generation) {
        try await Task.sleep(for: .milliseconds(25))
      }
      guard runtimes[namespaceID]?.generation == runtime.generation else {
        return
      }
    }

    intentionalTerminations.insert(runtime.generation)
    do {
      try await terminate(runtime.process)
    } catch {
      intentionalTerminations.remove(runtime.generation)
      publish(.failed(message: error.localizedDescription), for: namespaceID)
      throw error
    }
    if runtimes[namespaceID]?.generation == runtime.generation {
      runtimes.removeValue(forKey: namespaceID)
    }
    generations.removeValue(forKey: namespaceID)
    releasePort(for: namespaceID, generation: runtime.generation)
    intentionalTerminations.remove(runtime.generation)
    close(runtime)
    publish(.stopped, for: namespaceID)
  }

  public func stopAll() async throws {
    startSuspensionCount += 1
    defer { startSuspensionCount -= 1 }
    try await stopOwnedDaemons()
  }

  public func shutdownForApplicationTermination() async throws {
    applicationTerminationRequested = true
    do {
      try await stopOwnedDaemons()
    } catch {
      applicationTerminationRequested = false
      throw error
    }
  }

  private func stopOwnedDaemons() async throws {
    var failures: [Namespace.ID: String] = [:]
    for namespaceID in Set(generations.keys).union(runtimes.keys) {
      do {
        try await stop(namespaceID: namespaceID)
      } catch {
        failures[namespaceID] = error.localizedDescription
      }
    }
    if !failures.isEmpty {
      throw NamespaceDaemonStopAllError(failures: failures)
    }
  }

  public func state(for namespaceID: Namespace.ID) -> NamespaceDaemonState {
    states[namespaceID] ?? .stopped
  }

  private func isActive(_ namespaceID: Namespace.ID) -> Bool {
    switch states[namespaceID] ?? .stopped {
    case .starting, .running:
      true
    case .stopped, .failed:
      false
    }
  }

  private func requireExecutable() throws -> URL {
    guard let executableURL else {
      throw NamespaceDaemonError.executableNotFound
    }
    guard fileManager.isExecutableFile(atPath: executableURL.path) else {
      throw NamespaceDaemonError.executableNotExecutable(executableURL)
    }
    return executableURL
  }

  private func reservePort(for namespaceID: Namespace.ID, generation: UUID) throws -> UInt16 {
    for _ in 0..<100 {
      let port = try portAllocator()
      guard !portReservations.values.contains(where: { $0.port == port }) else {
        continue
      }
      portReservations[namespaceID] = (generation, port)
      return port
    }
    throw NamespaceDaemonError.endpointUnavailable
  }

  private func releasePort(for namespaceID: Namespace.ID, generation: UUID? = nil) {
    guard
      generation == nil || portReservations[namespaceID]?.generation == generation
    else {
      return
    }
    portReservations.removeValue(forKey: namespaceID)
  }

  private func prepareRuntime(in namespaceDirectory: URL) throws -> RuntimeLayout {
    let runtimeDirectory = namespaceDirectory.appendingPathComponent("Runtime", isDirectory: true)
    let workspaceDirectory = namespaceDirectory.appendingPathComponent(
      "Workspaces",
      isDirectory: true
    )
    let logsDirectory = namespaceDirectory.appendingPathComponent("Logs", isDirectory: true)

    do {
      for directory in [runtimeDirectory, workspaceDirectory, logsDirectory] {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      let workflowURL = runtimeDirectory.appendingPathComponent("WORKFLOW.md")
      try workflow(workspaceDirectory: workspaceDirectory).write(
        to: workflowURL,
        atomically: true,
        encoding: .utf8
      )
      return RuntimeLayout(
        workflowURL: workflowURL,
        logsDirectory: logsDirectory,
        standardOutputURL: logsDirectory.appendingPathComponent("daemon.stdout.log"),
        standardErrorURL: logsDirectory.appendingPathComponent("daemon.stderr.log")
      )
    } catch {
      throw NamespaceDaemonError.runtimePreparationFailed
    }
  }

  private func workflow(workspaceDirectory: URL) -> String {
    let escapedPath = workspaceDirectory.path.replacingOccurrences(of: "'", with: "''")
    return """
      ---
      tracker:
        kind: memory
      workspace:
        root: '\(escapedPath)'
      codex:
        command: codex app-server
      ---

      This namespace is waiting for a platform connection.
      """
  }

  private func launch(
    executableURL: URL,
    layout: RuntimeLayout,
    endpoint: URL,
    port: UInt16,
    namespaceID: Namespace.ID,
    generation: UUID
  ) throws -> Runtime {
    for logURL in [layout.standardOutputURL, layout.standardErrorURL] {
      if !fileManager.fileExists(atPath: logURL.path) {
        guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
          throw NamespaceDaemonError.runtimePreparationFailed
        }
      }
    }

    let output: FileHandle
    let errorOutput: FileHandle
    do {
      output = try FileHandle(forWritingTo: layout.standardOutputURL)
      do {
        errorOutput = try FileHandle(forWritingTo: layout.standardErrorURL)
      } catch {
        try? output.close()
        throw error
      }
      do {
        try output.seekToEnd()
        try errorOutput.seekToEnd()
      } catch {
        try? output.close()
        try? errorOutput.close()
        throw error
      }
    } catch {
      throw NamespaceDaemonError.runtimePreparationFailed
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments =
      argumentPrefix + [
        "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
        "--logs-root", layout.logsDirectory.path,
        "--port", String(port),
        layout.workflowURL.path,
      ]
    process.currentDirectoryURL = workingDirectoryURL
    process.standardOutput = output
    process.standardError = errorOutput
    let terminationDelivery = self.terminationDelivery
    process.terminationHandler = { [self, terminationDelivery] process in
      let status = process.terminationStatus
      terminationDelivery { [self] in
        await processDidTerminate(
          namespaceID: namespaceID,
          generation: generation,
          status: status
        )
      }
    }

    do {
      try process.run()
    } catch {
      try? output.close()
      try? errorOutput.close()
      throw NamespaceDaemonError.launchFailed
    }

    return Runtime(
      generation: generation,
      process: process,
      endpoint: endpoint,
      output: output,
      errorOutput: errorOutput
    )
  }

  private func waitUntilReady(_ runtime: Runtime, namespaceID: Namespace.ID) async -> Bool {
    let deadline = Date().addingTimeInterval(readinessTimeout)
    while Date() < deadline {
      guard
        generations[namespaceID] == runtime.generation,
        runtimes[namespaceID]?.generation == runtime.generation,
        runtime.process.isRunning
      else {
        return false
      }
      if await readinessProbe(runtime.endpoint) {
        return true
      }
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        return false
      }
    }
    return false
  }

  private func failCurrentAttempt(
    _ namespaceID: Namespace.ID,
    generation: UUID,
    error: Error
  ) async {
    guard generations[namespaceID] == generation else {
      return
    }
    guard !intentionalTerminations.contains(generation) else {
      return
    }
    if let runtime = runtimes[namespaceID], runtime.generation == generation {
      intentionalTerminations.insert(generation)
      do {
        try await terminate(runtime.process)
      } catch {
        intentionalTerminations.remove(generation)
        publish(.failed(message: error.localizedDescription), for: namespaceID)
        return
      }
      runtimes.removeValue(forKey: namespaceID)
      close(runtime)
    }
    intentionalTerminations.remove(generation)
    generations.removeValue(forKey: namespaceID)
    releasePort(for: namespaceID, generation: generation)
    publish(.failed(message: error.localizedDescription), for: namespaceID)
  }

  private func processDidTerminate(
    namespaceID: Namespace.ID,
    generation: UUID,
    status: Int32
  ) {
    guard
      let runtime = runtimes[namespaceID],
      runtime.generation == generation,
      generations[namespaceID] == generation
    else {
      return
    }
    guard !intentionalTerminations.contains(generation) else {
      return
    }
    runtimes.removeValue(forKey: namespaceID)
    generations.removeValue(forKey: namespaceID)
    releasePort(for: namespaceID, generation: generation)
    close(runtime)
    publish(
      .failed(
        message: """
          Symphony exited unexpectedly with status \(status). \
          Check Logs/daemon.stderr.log for this namespace, then restart it.
          """
      ),
      for: namespaceID
    )
  }

  private func terminate(_ process: Process) async throws {
    guard process.isRunning else {
      return
    }
    process.terminate()
    if try await waitForExit(process, timeout: gracefulStopTimeout) {
      return
    }
    guard forceKill(process.processIdentifier) == 0 else {
      throw NamespaceDaemonError.stopFailed
    }
    guard try await waitForExit(process, timeout: forcedStopTimeout) else {
      throw NamespaceDaemonError.stopFailed
    }
  }

  private func waitForExit(_ process: Process, timeout: TimeInterval) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    return !process.isRunning
  }

  private func close(_ runtime: Runtime) {
    try? runtime.output.close()
    try? runtime.errorOutput.close()
  }

  private func publish(_ state: NamespaceDaemonState, for namespaceID: Namespace.ID) {
    states[namespaceID] = state
    let event = NamespaceDaemonEvent(namespaceID: namespaceID, state: state)
    for continuation in eventContinuations.values {
      continuation.yield(event)
    }
  }

  private func removeEventContinuation(_ id: UUID) {
    eventContinuations.removeValue(forKey: id)
  }

  public static func probe(_ endpoint: URL) async -> Bool {
    var request = URLRequest(url: endpoint.appendingPathComponent("api/v1/state"))
    request.timeoutInterval = 0.5
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }

  public static func availableLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw NamespaceDaemonError.endpointUnavailable
    }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      throw NamespaceDaemonError.endpointUnavailable
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard nameResult == 0 else {
      throw NamespaceDaemonError.endpointUnavailable
    }
    return UInt16(bigEndian: boundAddress.sin_port)
  }
}

public struct NamespaceDaemonStopAllError: LocalizedError, Sendable {
  public let failures: [Namespace.ID: String]

  public var errorDescription: String? {
    "One or more Symphony daemons could not be stopped safely. Try again before quitting."
  }
}

public enum NamespaceDaemonError: LocalizedError, Sendable {
  case executableNotFound
  case executableNotExecutable(URL)
  case runtimePreparationFailed
  case endpointUnavailable
  case launchFailed
  case readinessTimedOut
  case stopFailed

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "The Symphony daemon executable could not be found. Reinstall the application and try again."
    case .executableNotExecutable(let url):
      "The Symphony daemon at \(url.path) is not executable. Reinstall the application and try again."
    case .runtimePreparationFailed:
      "The namespace runtime could not be prepared. Check disk space and permissions, then try again."
    case .endpointUnavailable:
      "A local communication endpoint could not be reserved. Try again."
    case .launchFailed:
      "The Symphony daemon could not be launched. Check the namespace daemon log and try again."
    case .readinessTimedOut:
      "The Symphony daemon did not become ready in time. Check the namespace daemon log and try again."
    case .stopFailed:
      "The Symphony daemon could not be stopped safely. Try again before deleting or locking the namespace."
    }
  }
}

private struct RuntimeLayout {
  let workflowURL: URL
  let logsDirectory: URL
  let standardOutputURL: URL
  let standardErrorURL: URL
}
