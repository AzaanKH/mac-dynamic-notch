import Foundation
import NotchRouterCore
import Testing

private let adapterCommand = "'/Users/me/Library/Application Support/NotchRouter/bin/notchctl' codex-hook"

private func temporaryHooksURL() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexHooksFileTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("hooks.json")
}

private func removeDirectory(of url: URL) {
  try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

private func hooks(at url: URL) throws -> [String: [[String: Any]]] {
  let root = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  )
  return try #require(root["hooks"] as? [String: [[String: Any]]])
}

private func commands(in groups: [[String: Any]]?) -> [String] {
  (groups ?? []).flatMap { group in
    (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
  }
}

@Test
func installingCreatesAHandlerForEachLifecycleEvent() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }

  try AgentHooksFile.codex.install(command: adapterCommand, at: url)

  let installed = try hooks(at: url)
  #expect(Set(installed.keys) == Set(AgentHooksFile.codex.eventNames))
  for eventName in AgentHooksFile.codex.eventNames {
    #expect(commands(in: installed[eventName]) == [adapterCommand])
  }
  // Codex reads the command verbatim, so the path must not be written as `\/`.
  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(text.contains("\"command\" : \"\(adapterCommand)\""))
}

@Test
func installingPreservesUnrelatedHooksAndReplacesAnEarlierInstall() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }
  try Data(
    """
    {
      "model": "kept",
      "hooks": {
        "Stop": [
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "say done" },
              { "type": "command", "command": "'/old/place/notchctl' codex-hook", "timeout": 2 }
            ]
          }
        ],
        "SessionStart": [
          { "hooks": [{ "type": "command", "command": "echo started" }] }
        ]
      }
    }
    """.utf8
  ).write(to: url)

  try AgentHooksFile.codex.install(command: adapterCommand, at: url)
  try AgentHooksFile.codex.install(command: adapterCommand, at: url)

  let root = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  )
  #expect(root["model"] as? String == "kept")
  let installed = try hooks(at: url)
  #expect(commands(in: installed["Stop"]) == ["say done", adapterCommand])
  #expect(installed["Stop"]?.first?["matcher"] as? String == "Bash")
  #expect(commands(in: installed["SessionStart"]) == ["echo started"])
  #expect(commands(in: installed["PostToolUse"]) == [adapterCommand])
}

@Test
func removingDeletesOnlyNotchRouterHandlers() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }
  try Data(
    """
    {
      "hooks": {
        "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }],
        "PreToolUse": [{ "hooks": [{ "type": "command", "command": "notchctl-lookalike check" }] }]
      }
    }
    """.utf8
  ).write(to: url)
  try AgentHooksFile.codex.install(command: adapterCommand, at: url)

  #expect(try AgentHooksFile.codex.remove(at: url) == .removed)

  let remaining = try hooks(at: url)
  #expect(Set(remaining.keys) == ["Stop", "PreToolUse"])
  #expect(commands(in: remaining["Stop"]) == ["say done"])
  #expect(commands(in: remaining["PreToolUse"]) == ["notchctl-lookalike check"])
}

@Test
func removingLeavesAFileWithoutNotchRouterHooksUntouched() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }

  #expect(try AgentHooksFile.codex.remove(at: url) == .noFile)
  #expect(!FileManager.default.fileExists(atPath: url.path))

  for contents in [
    #"{"model":"kept"}"#,
    #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#,
  ] {
    let original = Data(contents.utf8)
    try original.write(to: url)
    #expect(try AgentHooksFile.codex.remove(at: url) == .nothingToRemove)
    #expect(try Data(contentsOf: url) == original)
  }
}

@Test
func unsupportedFilesAreNeverRewritten() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }

  // Removal only fails when the file cannot be read as a JSON object. Any other
  // unexpected shape cannot hold a NotchRouter handler.
  for (contents, removalFails) in [
    ("not json", true),
    ("[]", true),
    (#"{"hooks":[]}"#, false),
    (#"{"hooks":{"Stop":{"hooks":[]}}}"#, false),
    (#"{"hooks":{"Stop":["say done"]}}"#, false),
  ] {
    let original = Data(contents.utf8)
    try original.write(to: url)
    #expect(throws: AgentHooksFileError.self) {
      try AgentHooksFile.codex.install(command: adapterCommand, at: url)
    }
    if removalFails {
      #expect(throws: AgentHooksFileError.self) {
        try AgentHooksFile.codex.remove(at: url)
      }
    } else {
      #expect(try AgentHooksFile.codex.remove(at: url) == .nothingToRemove)
    }
    #expect(try Data(contentsOf: url) == original)
  }
}

@Test
func writingThroughASymlinkKeepsTheLinkAndUpdatesItsTarget() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }
  let target = url.deletingLastPathComponent().appendingPathComponent("dotfiles-hooks.json")
  try Data(#"{"model":"kept"}"#.utf8).write(to: target)
  try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

  try AgentHooksFile.codex.install(command: adapterCommand, at: url)

  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
  #expect(commands(in: try hooks(at: target)["Stop"]) == [adapterCommand])

  #expect(try AgentHooksFile.codex.remove(at: url) == .removed)
  let afterRemoval = try FileManager.default.attributesOfItem(atPath: url.path)
  #expect(afterRemoval[.type] as? FileAttributeType == .typeSymbolicLink)
  #expect(try hooks(at: target).isEmpty)
}

@Test
func claudeHooksMergeIntoSettingsWithoutDisturbingOtherSettings() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClaudeSettings-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("settings.json")
  try Data(
    """
    {
      "model": "opus",
      "permissions": {"allow": ["Bash(git status)"]},
      "hooks": {
        "Stop": [{"hooks": [{"type": "command", "command": "afplay done.aiff"}]}],
        "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "echo hi"}]}]
      }
    }
    """.utf8
  ).write(to: url)
  let claudeCommand = "'/Users/me/Library/Application Support/NotchRouter/bin/notchctl' claude-hook"
  let file = AgentHooksFile.claudeCode

  #expect(!file.isInstalled(at: url))
  try file.install(command: claudeCommand, at: url)
  try file.install(command: claudeCommand, at: url)
  #expect(file.isInstalled(at: url))

  let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  #expect(root["model"] as? String == "opus")
  #expect((root["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(git status)"])
  #expect(root["description"] == nil, "Claude settings get no extra top-level keys")

  let installed = try hooks(at: url)
  #expect(commands(in: installed["Stop"]) == ["afplay done.aiff", claudeCommand])
  #expect(commands(in: installed["SessionStart"]) == ["echo hi"])
  for registration in file.registrations {
    let groups = try #require(installed[registration.eventName])
    let ours = try #require(groups.last)
    #expect(commands(in: [ours]) == [claudeCommand], "Repeated installs do not accumulate")
    #expect(ours["matcher"] as? String == registration.matcher)
  }
  #expect(installed["Notification"]?.last?["matcher"] as? String == "permission_prompt")

  // Only the frequent events run in the background; final and approval
  // states are delivered before the agent moves on.
  func isAsync(_ eventName: String) -> Bool {
    ((installed[eventName]?.last?["hooks"] as? [[String: Any]])?.first?["async"] as? Bool) == true
  }
  #expect(isAsync("PostToolUse") && isAsync("UserPromptSubmit"))
  #expect(!isAsync("Stop") && !isAsync("SessionEnd") && !isAsync("PermissionRequest") && !isAsync("Notification"))

  // Codex handlers are not Claude handlers, in either direction.
  #expect(!AgentHooksFile.codex.isInstalled(at: url))
  #expect(try AgentHooksFile.codex.remove(at: url) == .nothingToRemove)

  #expect(try file.remove(at: url) == .removed)
  let remaining = try hooks(at: url)
  #expect(commands(in: remaining["Stop"]) == ["afplay done.aiff"])
  #expect(remaining["UserPromptSubmit"] == nil)
  #expect(!file.isInstalled(at: url))
}

@Test
func codexHooksNeverRunInTheBackground() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }
  try AgentHooksFile.codex.install(command: adapterCommand, at: url)
  for groups in try hooks(at: url).values {
    for handler in groups.flatMap({ $0["hooks"] as? [[String: Any]] ?? [] }) {
      #expect(handler["async"] == nil)
    }
  }
}

@Test
func hookCommandRunsTheHelperAndExitsCleanlyWithoutIt() throws {
  let directory = URL(fileURLWithPath: "/tmp/notch-hook-\(UUID().uuidString)/it's here")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
  let helper = directory.appendingPathComponent("notchctl")
  let marker = directory.appendingPathComponent("ran")

  func run(_ command: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  let command = AgentHooksFile.claudeCode.command(helperPath: helper.path)
  #expect(command.hasSuffix(" claude-hook"), "Install and removal recognize it")
  #expect(AgentHooksFile.codex.command(helperPath: helper.path).hasSuffix(" codex-hook"))

  // Settings copied to a Mac without NotchRouter: no hook error.
  #expect(try run(command) == 0)
  #expect(!FileManager.default.fileExists(atPath: marker.path))

  // With the helper present, it runs with the agent's subcommand.
  try Data("#!/bin/sh\necho \"$1\" > \"$(dirname \"$0\")/ran\"\n".utf8).write(to: helper)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
  #expect(try run(command) == 0)
  #expect(try String(contentsOf: marker, encoding: .utf8) == "claude-hook\n")
}

@Test
func reinstallingKeepsEveryHookInPlaceForCodexTrust() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }
  let file = AgentHooksFile.codex
  try file.install(command: adapterCommand, at: url)
  // Another tool adds its own hook after NotchRouter's.
  var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  var hookTable = try #require(root["hooks"] as? [String: Any])
  var stop = try #require(hookTable["Stop"] as? [[String: Any]])
  stop.append(["matcher": "", "hooks": [["type": "command", "command": "other-tool stop"]]])
  hookTable["Stop"] = stop
  root["hooks"] = hookTable
  try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url)

  // Codex trusts `stop:0:0` and `stop:1:0` by position and command hash.
  try file.install(command: adapterCommand, at: url)
  let unchanged = try Data(contentsOf: url)
  #expect(commands(in: try hooks(at: url)["Stop"]) == [adapterCommand, "other-tool stop"])

  // An unchanged reinstall leaves the file as it was.
  try file.install(command: adapterCommand, at: url)
  #expect(try Data(contentsOf: url) == unchanged)

  // A new helper command replaces the handler where it was.
  let updated = "'/new/place/notchctl' codex-hook"
  try file.install(command: updated, at: url)
  #expect(commands(in: try hooks(at: url)["Stop"]) == [updated, "other-tool stop"])
  #expect(commands(in: try hooks(at: url)["PostToolUse"]) == [updated])
}
