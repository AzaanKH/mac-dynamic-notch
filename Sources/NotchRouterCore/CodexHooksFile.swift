import Foundation

/// Adds and removes NotchRouter's handlers in a Codex `hooks.json`, leaving
/// every other hook, matcher, and top-level key as the user wrote it.
public enum CodexHooksFile {
  public static let eventNames = [
    "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop",
  ]

  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("hooks.json")
  }

  public enum RemovalResult: Equatable, Sendable {
    case noFile
    case nothingToRemove
    case removed
  }

  /// Registers `command` for each lifecycle event, replacing any earlier
  /// NotchRouter handler so repeated installs do not accumulate.
  public static func install(command: String, at url: URL = defaultURL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var root: [String: Any] = [
      "description":
        "Publishes Codex task titles, response excerpts, and lifecycle state to local NotchRouter."
    ]
    if FileManager.default.fileExists(atPath: url.path) {
      root = try readRoot(at: url)
    }

    var hooks = try hooksObject(in: root) ?? [:]
    for eventName in eventNames {
      var groups = removingAdapterHandlers(from: try groups(for: eventName, in: hooks))
      groups.append([
        "hooks": [
          [
            "type": "command",
            "command": command,
            "timeout": 2,
          ]
        ]
      ])
      hooks[eventName] = groups
    }
    root["hooks"] = hooks
    try write(root, to: url)
  }

  /// Removes only NotchRouter's handlers. The file is left untouched when it
  /// holds none.
  @discardableResult
  public static func remove(at url: URL = defaultURL) throws -> RemovalResult {
    guard FileManager.default.fileExists(atPath: url.path) else { return .noFile }

    var root = try readRoot(at: url)
    // NotchRouter only writes arrays of groups, so any other shape holds none
    // of its handlers and is left alone rather than rejected.
    guard var hooks = root["hooks"] as? [String: Any] else { return .nothingToRemove }

    var didRemove = false
    for eventName in eventNames {
      guard let existing = hooks[eventName] as? [[String: Any]],
        containsAdapterHandler(existing)
      else { continue }
      didRemove = true
      let filtered = removingAdapterHandlers(from: existing)
      if filtered.isEmpty {
        hooks.removeValue(forKey: eventName)
      } else {
        hooks[eventName] = filtered
      }
    }
    guard didRemove else { return .nothingToRemove }

    root["hooks"] = hooks
    try write(root, to: url)
    return .removed
  }

  private static func readRoot(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      throw CodexHooksFileError.unsupportedStructure
    }
    return root
  }

  private static func hooksObject(in root: [String: Any]) throws -> [String: Any]? {
    guard let value = root["hooks"] else { return nil }
    guard let hooks = value as? [String: Any] else {
      throw CodexHooksFileError.unsupportedStructure
    }
    return hooks
  }

  private static func groups(
    for eventName: String,
    in hooks: [String: Any]
  ) throws -> [[String: Any]] {
    guard let value = hooks[eventName] else { return [] }
    guard let groups = value as? [[String: Any]] else {
      throw CodexHooksFileError.unsupportedStructure
    }
    return groups
  }

  private static func isAdapterHandler(_ handler: [String: Any]) -> Bool {
    guard let command = handler["command"] as? String else { return false }
    return command.contains("notchctl") && command.hasSuffix(" codex-hook")
  }

  private static func containsAdapterHandler(_ groups: [[String: Any]]) -> Bool {
    groups.contains { group in
      (group["hooks"] as? [[String: Any]])?.contains(where: isAdapterHandler) ?? false
    }
  }

  private static func removingAdapterHandlers(
    from groups: [[String: Any]]
  ) -> [[String: Any]] {
    groups.compactMap { group in
      guard let handlers = group["hooks"] as? [[String: Any]] else {
        return group
      }
      let remainingHandlers = handlers.filter { !isAdapterHandler($0) }
      guard !remainingHandlers.isEmpty else { return nil }
      var updatedGroup = group
      updatedGroup["hooks"] = remainingHandlers
      return updatedGroup
    }
  }

  private static func write(_ root: [String: Any], to url: URL) throws {
    var data = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    // An atomic write replaces the item at the path. Writing through a symlink
    // keeps a hooks file that is managed elsewhere, such as in a dotfiles
    // repository, linked to its real location.
    let destination = url.resolvingSymlinksInPath()
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
  }
}

public enum CodexHooksFileError: LocalizedError, Sendable {
  case unsupportedStructure

  public var errorDescription: String? {
    switch self {
    case .unsupportedStructure:
      "~/.codex/hooks.json does not have the expected structure, so it was left unchanged."
    }
  }
}
