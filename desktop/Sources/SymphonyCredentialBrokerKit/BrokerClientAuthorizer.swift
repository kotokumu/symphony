import Darwin
import Foundation
import Security

public protocol BrokerParentProcessInspecting: Sendable {
  func parentProcessID() -> pid_t
  func executableURL(for processID: pid_t) throws -> URL
}

public protocol BrokerCodeSignatureChecking: Sendable {
  func process(_ processID: pid_t, satisfiesCodeAt executableURL: URL) throws -> Bool
}

public struct ParentCodeSignatureBrokerClientAuthorizer: Sendable {
  private let processInspector: any BrokerParentProcessInspecting
  private let codeSignatureChecker: any BrokerCodeSignatureChecking
  private let helperExecutableURL: URL

  public init(
    processInspector: any BrokerParentProcessInspecting = SystemBrokerParentProcessInspector(),
    codeSignatureChecker: any BrokerCodeSignatureChecking = SystemBrokerCodeSignatureChecker(),
    helperExecutableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])
  ) {
    self.processInspector = processInspector
    self.codeSignatureChecker = codeSignatureChecker
    self.helperExecutableURL = helperExecutableURL.standardizedFileURL
  }

  public func authorizeCaller() throws {
    let expectedDesktopURL = expectedDesktopExecutableURL()
    let parentProcessID = processInspector.parentProcessID()
    let parentExecutableURL = try processInspector.executableURL(for: parentProcessID)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    guard
      parentExecutableURL == expectedDesktopURL.resolvingSymlinksInPath().standardizedFileURL,
      try codeSignatureChecker.process(
        parentProcessID,
        satisfiesCodeAt: expectedDesktopURL
      )
    else {
      throw BrokerClientAuthorizationError.untrustedCaller
    }
  }

  public func expectedDesktopExecutableURL() -> URL {
    let helperDirectory = helperExecutableURL.deletingLastPathComponent()
    if helperDirectory.lastPathComponent == "Helpers",
      helperDirectory.deletingLastPathComponent().lastPathComponent == "Contents"
    {
      return helperDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("MacOS", isDirectory: true)
        .appendingPathComponent("SymphonyDesktop")
    }
    return helperDirectory.appendingPathComponent("SymphonyDesktop")
  }
}

public struct SystemBrokerParentProcessInspector: BrokerParentProcessInspecting {
  public init() {}

  public func parentProcessID() -> pid_t {
    getppid()
  }

  public func executableURL(for processID: pid_t) throws -> URL {
    var path = [CChar](repeating: 0, count: 4_096)
    let length = proc_pidpath(processID, &path, UInt32(path.count))
    guard length > 0 else {
      throw BrokerClientAuthorizationError.parentUnavailable
    }
    let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
  }
}

public struct SystemBrokerCodeSignatureChecker: BrokerCodeSignatureChecking {
  public init() {}

  public func process(_ processID: pid_t, satisfiesCodeAt executableURL: URL) throws -> Bool {
    var expectedCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(executableURL as CFURL, [], &expectedCode) == errSecSuccess,
      let expectedCode
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }

    var requirement: SecRequirement?
    guard
      SecCodeCopyDesignatedRequirement(expectedCode, [], &requirement) == errSecSuccess,
      let requirement
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }

    var parentCode: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)]
    guard
      SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &parentCode)
        == errSecSuccess,
      let parentCode
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }

    return SecCodeCheckValidity(parentCode, [], requirement) == errSecSuccess
  }
}

public enum BrokerClientAuthorizationError: LocalizedError, Sendable {
  case parentUnavailable
  case signatureUnavailable
  case untrustedCaller

  public var errorDescription: String? {
    switch self {
    case .parentUnavailable, .signatureUnavailable, .untrustedCaller:
      "The native credential broker rejected an untrusted caller."
    }
  }
}
