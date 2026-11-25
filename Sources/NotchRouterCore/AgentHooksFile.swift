import Foundation

/// Adds and removes NotchRouter's handlers in an agent's hooks file (Codex
/// `~/.codex/hooks.json`, Claude Code `~/.claude/settings.json`), leaving every
/// other hook, matcher, setting, and top-level key as the user wrote it.
public struct AgentHooksFile: Sendable {
  public struct Registration: Equatable, Sendable {
    public let eventName: String
    /// Claude Code filters tool events by tool name and `Notification` by
    /// notification type. `nil` writes a group without a matcher.
    public let matcher: String?
    /// Runs in the background instead of holding up the agent. Used for the
    /// frequent events only; events carry their start time, so late delivery
    /// cannot move an activity backwards.
    public var isAsync = false
  }

  public let agent: CodingAgent
  public let registrations: [Registration]
  public let defaultURL: URL
  /// Written only when the file is created. Claude Code's settings file is
  /// shared with every other setting, so it gets none.
  private let newFileDescription: String?

  public static let codex = AgentHooksFile(
    agent: .codex,
    registrations: ["UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"]
      .map { Registration(eventName: $0, matcher: nil) },
    defaultURL: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/hooks.json"),
    newFileDescription:
      "Publishes Codex task titles, response excerpts, and lifecycle state to local NotchRouter."
  )

  /// User-level settings also apply to Claude Code sessions that T3 Code
  /// starts, so one install covers the CLI and T3 Code's Claude threads.
  public static let claudeCode = AgentHooksFile(
    agent: .claudeCode,
    // Stop, SessionEnd, and approvals stay synchronous: they are rare, carry
    // the states that must not be lost, and a one-shot `claude -p` run can
    // exit right after Stop, before a background hook finishes.
    registrations: [
      Registration(eventName: "UserPromptSubmit", matcher: nil, isAsync: true),
      Registration(eventName: "PermissionRequest", matcher: "*"),
      Registration(eventName: "PostToolUse", matcher: "*", isAsync: true),
      Registration(eventName: "Notification", matcher: "permission_prompt"),
      Registration(eventName: "Stop", matcher: nil),
      // Runs instead of Stop when an API error, such as a usage limit, ends
      // the turn. Without it the activity would stay "Working".
      Registration(eventName: "StopFailure", matcher: nil),
      Registration(eventName: "SessionEnd", matcher: nil),
    ],
    defaultURL: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/settings.json"),
    newFileDescription: nil
  )

  public var eventNames: [String] { registrations.map(\.eventName) }

  /// The hook command for the helper at `helperPath`. It exits successfully
  /// without the helper, so settings copied to a Mac without NotchRouter
  /// (for example through dotfiles) do not report a hook error on every
  /// tool call. Both agents run hook commands through a POSIX shell.
  public func command(helperPath: String) -> String {
    let helper = "'\(helperPath.replacingOccurrences(of: "'", with: "'\\''"))'"
    return "[ ! -x \(helper) ] || \(helper) \(agent.hookCommand)"
  }

  public enum RemovalResult: Equatable, Sendable {
    case noFile
    case nothingToRemove
    case removed
  }

  /// Registers `command` for each lifecycle event, replacing any earlier
  /// NotchRouter handler so repeated installs do not accumulate.
  public func install(command: String, at url: URL? = nil) throws {
    let url = url ?? defaultURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var root: [String: Any] = newFileDescription.map { ["description": $0] } ?? [:]
    if FileManager.default.fileExists(atPath: url.path) {
      root = try readRoot(at: url)
    }

    var hooks = try hooksObject(in: root) ?? [:]
    for registration in registrations {
      var handler: [String: Any] = [
        "type": "command",
        "command": command,
        "timeout": 2,
      ]
      if registration.isAsync { handler["async"] = true }
      hooks[registration.eventName] = replacingAdapterHandler(
        in: try groups(for: registration.eventName, in: hooks),
        with: handler,
        matcher: registration.matcher
      )
    }
    root["hooks"] = hooks
    try write(root, to: url)
  }

  /// Whether the file holds a NotchRouter handler for this agent.
  public func isInstalled(at url: URL? = nil) -> Bool {
    guard let root = try? readRoot(at: url ?? defaultURL),
      let hooks = root["hooks"] as? [String: Any]
    else { return false }
    return eventNames.contains { eventName in
      (hooks[eventName] as? [[String: Any]]).map(containsAdapterHandler) ?? false
    }
  }

  /// Whether an install from an earlier version lacks an event this version
  /// registers. Reinstalling adds it.
  public func isMissingEvents(at url: URL? = nil) -> Bool {
    guard let root = try? readRoot(at: url ?? defaultURL),
      let hooks = root["hooks"] as? [String: Any],
      isInstalled(at: url)
    else { return false }
    return eventNames.contains { eventName in
      !((hooks[eventName] as? [[String: Any]]).map(containsAdapterHandler) ?? false)
    }
  }

  /// Removes only NotchRouter's handlers. The file is left untouched when it
  /// holds none.
  @discardableResult
  public func remove(at url: URL? = nil) throws -> RemovalResult {
    let url = url ?? defaultURL
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

  private func readRoot(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      throw AgentHooksFileError.unsupportedStructure(url.path)
    }
    return root
  }

  private func hooksObject(in root: [String: Any]) throws -> [String: Any]? {
    guard let value = root["hooks"] else { return nil }
    guard let hooks = value as? [String: Any] else {
      throw AgentHooksFileError.unsupportedStructure(defaultURL.path)
    }
    return hooks
  }

  private func groups(
    for eventName: String,
    in hooks: [String: Any]
  ) throws -> [[String: Any]] {
    guard let value = hooks[eventName] else { return [] }
    guard let groups = value as? [[String: Any]] else {
      throw AgentHooksFileError.unsupportedStructure(defaultURL.path)
    }
    return groups
  }

  private func isAdapterHandler(_ handler: [String: Any]) -> Bool {
    guard let command = handler["command"] as? String else { return false }
    return command.contains("notchctl") && command.hasSuffix(" \(agent.hookCommand)")
  }

  private func containsAdapterHandler(_ groups: [[String: Any]]) -> Bool {
    groups.contains { group in
      (group["hooks"] as? [[String: Any]])?.contains(where: isAdapterHandler) ?? false
    }
  }

  /// Puts `handler` where the first earlier NotchRouter handler was, and
  /// appends a new group only on a first install. Codex records hook trust by
  /// position (`stop:0:0`), so moving handlers on a reinstall would ask the
  /// user to review this hook and other tools' hooks again.
  private func replacingAdapterHandler(
    in groups: [[String: Any]],
    with handler: [String: Any],
    matcher: String?
  ) -> [[String: Any]] {
    var placed = false
    var result: [[String: Any]] = []
    for group in groups {
      guard let handlers = group["hooks"] as? [[String: Any]],
        handlers.contains(where: isAdapterHandler)
      else {
        result.append(group)
        continue
      }
      var updatedGroup = group
      if placed {
        // A duplicate from an older install: drop it.
        let remaining = handlers.filter { !isAdapterHandler($0) }
        guard !remaining.isEmpty else { continue }
        updatedGroup["hooks"] = remaining
      } else {
        placed = true
        let position = handlers.firstIndex(where: isAdapterHandler)!
        var updatedHandlers = handlers.enumerated()
          .filter { $0.offset == position || !isAdapterHandler($0.element) }
          .map(\.element)
        updatedHandlers[updatedHandlers.firstIndex(where: isAdapterHandler)!] = handler
        updatedGroup["hooks"] = updatedHandlers
        // A group the user shares with their own handlers keeps its matcher.
        if updatedHandlers.count == 1 {
          updatedGroup["matcher"] = matcher
        }
      }
      result.append(updatedGroup)
    }
    if !placed {
      var group: [String: Any] = ["hooks": [handler]]
      if let matcher { group["matcher"] = matcher }
      result.append(group)
    }
    return result
  }

  private func removingAdapterHandlers(
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

  private func write(_ root: [String: Any], to url: URL) throws {
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

public enum AgentHooksFileError: LocalizedError, Equatable, Sendable {
  case unsupportedStructure(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedStructure(let path):
      "\(path) does not have the expected structure, so it was left unchanged."
    }
  }
}
