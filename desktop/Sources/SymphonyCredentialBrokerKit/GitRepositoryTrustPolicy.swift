import Darwin
import CryptoKit
import Foundation
import SymphonyCredentialBrokerProtocol

struct ValidatedGitOperationPlan: Equatable, Sendable {
  let request: GitRepositoryCapabilityRequest
  let repositoryURL: URL
  let targetURL: URL
  let rootIdentity: FileIdentity
  let targetIdentity: FileIdentity?
  let metadataIdentity: FileIdentity?
  let configurationFingerprint: Data?
  let arguments: [String]
}

struct GitRepositoryTrustPolicy: Sendable {
  func validate(
    _ request: GitRepositoryCapabilityRequest,
    in scope: AuthorizedGitHubRepositoryScope
  ) throws -> ValidatedGitOperationPlan {
    try requireRootIdentity(scope)
    switch request {
    case .clone(let targetName):
      try requireChildName(targetName)
      let target = scope.workspacesRoot.appendingPathComponent(targetName, isDirectory: true)
      var information = stat()
      guard lstat(target.path, &information) != 0, errno == ENOENT else {
        throw GitRepositoryTrustError.targetAlreadyExists
      }
      return ValidatedGitOperationPlan(
        request: request,
        repositoryURL: scope.repositoryURL,
        targetURL: target,
        rootIdentity: scope.workspacesRootIdentity,
        targetIdentity: nil,
        metadataIdentity: nil,
        configurationFingerprint: nil,
        arguments: ["clone", "--", scope.repositoryURL.absoluteString, target.path]
      )
    case .fetch(let repositoryName):
      return try existingRepositoryPlan(
        request,
        repositoryName: repositoryName,
        branch: nil,
        scope: scope
      )
    case .push(let repositoryName, let branch):
      guard Self.isValidBranch(branch) else { throw GitRepositoryTrustError.invalidBranch }
      return try existingRepositoryPlan(
        request,
        repositoryName: repositoryName,
        branch: branch,
        scope: scope
      )
    }
  }

  func revalidate(_ plan: ValidatedGitOperationPlan, in scope: AuthorizedGitHubRepositoryScope) throws {
    let replacement = try validate(plan.request, in: scope)
    guard replacement.rootIdentity == plan.rootIdentity,
      replacement.targetIdentity == plan.targetIdentity,
      replacement.metadataIdentity == plan.metadataIdentity,
      replacement.configurationFingerprint == plan.configurationFingerprint,
      replacement.arguments == plan.arguments
    else {
      throw GitRepositoryTrustError.filesystemChanged
    }
  }

  func revalidate(
    _ plan: ValidatedGitOperationPlan,
    in scope: AuthorizedGitHubRepositoryScope,
    preparedCloneIdentity: FileIdentity?,
    preparedCloneURL: URL? = nil
  ) throws {
    if case .clone = plan.request, let preparedCloneIdentity {
      try requireRootIdentity(scope)
      guard try directoryIdentity(preparedCloneURL ?? plan.targetURL) == preparedCloneIdentity else {
        throw GitRepositoryTrustError.filesystemChanged
      }
      var desired = stat()
      guard lstat(plan.targetURL.path, &desired) != 0, errno == ENOENT else {
        throw GitRepositoryTrustError.filesystemChanged
      }
      return
    }
    try revalidate(plan, in: scope)
  }

  static func isValidBranch(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 244, value != "@",
      !value.hasPrefix("-"), !value.hasPrefix("/"),
      !value.hasSuffix("/"), !value.hasSuffix("."),
      !value.contains(".."), !value.contains("//"), !value.contains("@{"),
      !value.contains("\\")
    else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({
      !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
        && !$0.lowercased().hasSuffix(".lock")
    }) else { return false }
    return value.utf8.allSatisfy {
      (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
        || (0x61...0x7A).contains($0) || [0x2D, 0x2E, 0x2F, 0x5F].contains($0)
    }
  }

  private func existingRepositoryPlan(
    _ request: GitRepositoryCapabilityRequest,
    repositoryName: String,
    branch: String?,
    scope: AuthorizedGitHubRepositoryScope
  ) throws -> ValidatedGitOperationPlan {
    try requireChildName(repositoryName)
    let target = scope.workspacesRoot.appendingPathComponent(repositoryName, isDirectory: true)
    let targetIdentity = try directoryIdentity(target)
    let metadata = target.appendingPathComponent(".git", isDirectory: true)
    let metadataIdentity = try directoryIdentity(metadata)
    let config = metadata.appendingPathComponent("config")
    try requireRegularFile(config)
    try requireConfinedMetadata(metadata)
    let data = try Data(contentsOf: config, options: [.mappedIfSafe])
    guard data.count <= 256 * 1_024 else { throw GitRepositoryTrustError.invalidConfiguration }
    try validateConfiguration(data, scope: scope)
    let fingerprint = Data(SHA256.hash(data: data))
    let arguments: [String]
    if let branch {
      arguments = [
        "-C", target.path, "push", "--porcelain", "--",
        scope.repositoryURL.absoluteString, "HEAD:refs/heads/\(branch)",
      ]
    } else {
      arguments = [
        "-C", target.path, "fetch", "--prune", "--",
        scope.repositoryURL.absoluteString,
      ]
    }
    return ValidatedGitOperationPlan(
      request: request,
      repositoryURL: scope.repositoryURL,
      targetURL: target,
      rootIdentity: scope.workspacesRootIdentity,
      targetIdentity: targetIdentity,
      metadataIdentity: metadataIdentity,
      configurationFingerprint: fingerprint,
      arguments: arguments
    )
  }

  private func requireRootIdentity(_ scope: AuthorizedGitHubRepositoryScope) throws {
    guard try directoryIdentity(scope.workspacesRoot) == scope.workspacesRootIdentity else {
      throw GitRepositoryTrustError.filesystemChanged
    }
  }

  private func requireChildName(_ value: String) throws {
    guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255,
      !value.contains("/"), !value.unicodeScalars.contains(where: {
        $0.value == 0 || CharacterSet.controlCharacters.contains($0)
      })
    else { throw GitRepositoryTrustError.invalidTarget }
  }

  private func directoryIdentity(_ url: URL) throws -> FileIdentity {
    var information = stat()
    guard lstat(url.path, &information) == 0,
      information.st_mode & S_IFMT == S_IFDIR
    else { throw GitRepositoryTrustError.invalidRepository }
    return FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
  }

  private func requireRegularFile(_ url: URL) throws {
    var information = stat()
    guard lstat(url.path, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG
    else { throw GitRepositoryTrustError.invalidConfiguration }
  }

  private func requireConfinedMetadata(_ metadata: URL) throws {
    for name in ["commondir", "gitdir", "objects/info/alternates"] {
      guard !FileManager.default.fileExists(atPath: metadata.appendingPathComponent(name).path) else {
        throw GitRepositoryTrustError.externalMetadata
      }
    }
    guard let enumerator = FileManager.default.enumerator(
      at: metadata,
      includingPropertiesForKeys: [.isSymbolicLinkKey],
      options: []
    ) else { throw GitRepositoryTrustError.invalidRepository }
    var count = 0
    for case let url as URL in enumerator {
      count += 1
      guard count <= 100_000 else { throw GitRepositoryTrustError.invalidRepository }
      if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        throw GitRepositoryTrustError.externalMetadata
      }
    }
  }

  private func validateConfiguration(
    _ data: Data,
    scope: AuthorizedGitHubRepositoryScope
  ) throws {
    guard let text = String(data: data, encoding: .utf8) else {
      throw GitRepositoryTrustError.invalidConfiguration
    }
    var section = ""
    var originCount = 0
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
      if line.hasPrefix("[") && line.hasSuffix("]") {
        section = String(line.dropFirst().dropLast())
        continue
      }
      guard let separator = line.firstIndex(of: "=") else {
        throw GitRepositoryTrustError.invalidConfiguration
      }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      switch (section.lowercased(), key) {
      case ("core", "repositoryformatversion") where value == "0": break
      case ("core", let name)
        where ["filemode", "logallrefupdates", "ignorecase", "precomposeunicode"].contains(name)
          && (value == "true" || value == "false"): break
      case ("core", "bare") where value == "false": break
      case ("remote \"origin\"", "url"):
        guard GitHubRepositoryIdentity(owner: scope.owner, repository: scope.repository)
          .matches(URL(string: value) ?? URL(fileURLWithPath: ""))
        else { throw GitRepositoryTrustError.repositoryMismatch }
        originCount += 1
      case ("remote \"origin\"", "fetch")
        where value == "+refs/heads/*:refs/remotes/origin/*": break
      default:
        if section.lowercased().hasPrefix("branch \"") && section.hasSuffix("\"") {
          let name = String(section.dropFirst(8).dropLast())
          guard Self.isValidBranch(name),
            (key == "remote" && value == "origin"
              || key == "merge" && value == "refs/heads/\(name)")
          else { throw GitRepositoryTrustError.invalidConfiguration }
        } else {
          throw GitRepositoryTrustError.invalidConfiguration
        }
      }
    }
    guard originCount == 1 else { throw GitRepositoryTrustError.invalidConfiguration }
  }
}

enum GitRepositoryTrustError: LocalizedError, Sendable {
  case invalidTarget, targetAlreadyExists, invalidRepository, invalidConfiguration
  case repositoryMismatch, invalidBranch, externalMetadata, filesystemChanged

  var errorDescription: String? {
    "The Git repository is outside this namespace's authorized workspace or has unsafe configuration."
  }
}
