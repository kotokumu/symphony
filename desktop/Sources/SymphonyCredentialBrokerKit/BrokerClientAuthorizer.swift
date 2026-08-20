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
  private let security: any BrokerSecurityValidating

  public init() {
    security = SystemBrokerSecurityValidator()
  }

  init(security: any BrokerSecurityValidating) {
    self.security = security
  }

  public func process(
    _ processID: pid_t,
    satisfiesDesktopIdentifier desktopIdentifier: String,
    desktopExecutableURL: URL,
    helperExecutableURL: URL,
    containingAppURL: URL
  ) throws -> Bool {
    let teamIdentifier = try security.currentProcessSigningTeamIdentifier()
    guard !teamIdentifier.isEmpty else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }
    let requirementSource = Self.desktopRequirementSource(
      desktopIdentifier: desktopIdentifier,
      teamIdentifier: teamIdentifier
    )
    guard try security.staticCodeIsValid(at: containingAppURL, requirementSource: nil) else {
      return false
    }
    guard
      try security.staticCodeIsValid(
        at: desktopExecutableURL,
        requirementSource: requirementSource
      )
    else {
      return false
    }
    return try security.processIsValid(processID, requirementSource: requirementSource)
  }

  static func desktopRequirementSource(
    desktopIdentifier: String,
    teamIdentifier: String
  ) -> String {
    let escapedIdentifier = desktopIdentifier.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedTeam = teamIdentifier.replacingOccurrences(of: "\"", with: "\\\"")
    return
      "anchor apple generic and identifier \"\(escapedIdentifier)\" and certificate leaf[subject.OU] = \"\(escapedTeam)\""
  }
}

protocol BrokerSecurityValidating: Sendable {
  func currentProcessSigningTeamIdentifier() throws -> String
  func staticCodeIsValid(at url: URL, requirementSource: String?) throws -> Bool
  func processIsValid(_ processID: pid_t, requirementSource: String) throws -> Bool
}

private struct SystemBrokerSecurityValidator: BrokerSecurityValidating {
  func currentProcessSigningTeamIdentifier() throws -> String {
    var code: SecCode?
    guard
      SecCodeCopySelf([], &code) == errSecSuccess,
      let code,
      SecCodeCheckValidity(code, [], nil) == errSecSuccess
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }
    var information: CFDictionary?
    let signingInformation = SecCSFlags(
      rawValue: UInt32(kSecCSSigningInformation | kSecCSDynamicInformation)
    )
    // The C API accepts either SecCodeRef or SecStaticCodeRef, but the Swift overlay exposes only
    // the static type. Preserve the dynamic CF object so signing data comes from the running helper.
    let dynamicallyTypedCode = unsafeBitCast(code, to: SecStaticCode.self)
    guard
      SecCodeCopySigningInformation(
        dynamicallyTypedCode,
        signingInformation,
        &information
      ) == errSecSuccess,
      let dictionary = information as? [String: Any],
      let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }
    return teamIdentifier
  }

  func staticCodeIsValid(at url: URL, requirementSource: String?) throws -> Bool {
    let code = try staticCode(at: url)
    let codeRequirement: SecRequirement?
    if let requirementSource {
      codeRequirement = try requirement(from: requirementSource)
    } else {
      codeRequirement = nil
    }
    let allArchitectures = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures))
    return SecStaticCodeCheckValidity(code, allArchitectures, codeRequirement) == errSecSuccess
  }

  func processIsValid(_ processID: pid_t, requirementSource: String) throws -> Bool {
    let requirement = try requirement(from: requirementSource)
    var processCode: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)]
    guard
      SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &processCode)
        == errSecSuccess,
      let processCode
    else {
      throw BrokerClientAuthorizationError.signatureUnavailable
    }
    return SecCodeCheckValidity(processCode, [], requirement) == errSecSuccess
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

  private func requirement(from source: String) throws -> SecRequirement {
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
