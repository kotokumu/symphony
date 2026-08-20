import Darwin
import Foundation
import Security

public protocol BrokerParentProcessInspecting: Sendable {
  func parentProcessID() -> pid_t
  func executableURL(for processID: pid_t) throws -> URL
}

public protocol BrokerCodeSignatureChecking: Sendable {
  func process(
    _ processID: pid_t,
    satisfiesDesktopIdentifier desktopIdentifier: String,
    desktopExecutableURL: URL,
    helperExecutableURL: URL,
    containingAppURL: URL
  ) throws -> Bool
}

public struct ParentCodeSignatureBrokerClientAuthorizer: Sendable {
  public static let desktopSigningIdentifier = "com.kotokumu.symphony.desktop"

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
    self.helperExecutableURL = helperExecutableURL.resolvingSymlinksInPath().standardizedFileURL
  }

  public func authorizeCaller() throws {
    let layout = try packagedApplicationLayout()
    let parentProcessID = processInspector.parentProcessID()
    let parentExecutableURL = try processInspector.executableURL(for: parentProcessID)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    guard
      parentExecutableURL == layout.desktopExecutableURL,
      try codeSignatureChecker.process(
        parentProcessID,
        satisfiesDesktopIdentifier: Self.desktopSigningIdentifier,
        desktopExecutableURL: layout.desktopExecutableURL,
        helperExecutableURL: helperExecutableURL,
        containingAppURL: layout.appURL
      )
    else {
      throw BrokerClientAuthorizationError.untrustedCaller
    }
  }

  private func packagedApplicationLayout() throws -> (
    appURL: URL,
    desktopExecutableURL: URL
  ) {
    let helpersURL = helperExecutableURL.deletingLastPathComponent()
    let contentsURL = helpersURL.deletingLastPathComponent()
    let appURL = contentsURL.deletingLastPathComponent()
    guard
      helpersURL.lastPathComponent == "Helpers",
      contentsURL.lastPathComponent == "Contents",
      appURL.pathExtension == "app",
      helperExecutableURL.lastPathComponent == "SymphonyCredentialBroker"
    else {
      throw BrokerClientAuthorizationError.untrustedCaller
    }
    return (
      appURL,
      contentsURL
        .appendingPathComponent("MacOS", isDirectory: true)
        .appendingPathComponent("SymphonyDesktop")
        .resolvingSymlinksInPath()
        .standardizedFileURL
    )
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

  public func process(
    _ processID: pid_t,
    satisfiesDesktopIdentifier desktopIdentifier: String,
    desktopExecutableURL: URL,
    helperExecutableURL: URL,
    containingAppURL: URL
  ) throws -> Bool {
    let helperCode = try staticCode(at: helperExecutableURL)
    let signingInformation = try signingInformation(for: helperCode)
    guard
      let teamIdentifier = signingInformation[kSecCodeInfoTeamIdentifier as String] as? String,
      !teamIdentifier.isEmpty
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }

    let requirement = try requirement(
      desktopIdentifier: desktopIdentifier,
      teamIdentifier: teamIdentifier
    )
    let appCode = try staticCode(at: containingAppURL)
    let allArchitectures = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures))
    guard SecStaticCodeCheckValidity(appCode, allArchitectures, nil) == errSecSuccess else {
      return false
    }
    let desktopCode = try staticCode(at: desktopExecutableURL)
    guard SecStaticCodeCheckValidity(desktopCode, allArchitectures, requirement) == errSecSuccess
    else {
      return false
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

  private func staticCode(at url: URL) throws -> SecStaticCode {
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
      let code
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }
    return code
  }

  private func signingInformation(for code: SecStaticCode) throws -> [String: Any] {
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
      let information
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }
    return information as? [String: Any] ?? [:]
  }

  private func requirement(
    desktopIdentifier: String,
    teamIdentifier: String
  ) throws -> SecRequirement {
    let escapedIdentifier = desktopIdentifier.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedTeam = teamIdentifier.replacingOccurrences(of: "\"", with: "\\\"")
    let source =
      "anchor apple generic and identifier \"\(escapedIdentifier)\" and certificate leaf[subject.OU] = \"\(escapedTeam)\""
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }
    return requirement
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
