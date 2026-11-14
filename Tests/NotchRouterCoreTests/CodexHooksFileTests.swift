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

  try CodexHooksFile.install(command: adapterCommand, at: url)

  let installed = try hooks(at: url)
  #expect(Set(installed.keys) == Set(CodexHooksFile.eventNames))
  for eventName in CodexHooksFile.eventNames {
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

  try CodexHooksFile.install(command: adapterCommand, at: url)
  try CodexHooksFile.install(command: adapterCommand, at: url)

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
  try CodexHooksFile.install(command: adapterCommand, at: url)

  #expect(try CodexHooksFile.remove(at: url) == .removed)

  let remaining = try hooks(at: url)
  #expect(Set(remaining.keys) == ["Stop", "PreToolUse"])
  #expect(commands(in: remaining["Stop"]) == ["say done"])
  #expect(commands(in: remaining["PreToolUse"]) == ["notchctl-lookalike check"])
}

@Test
func removingLeavesAFileWithoutNotchRouterHooksUntouched() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }

  #expect(try CodexHooksFile.remove(at: url) == .noFile)
  #expect(!FileManager.default.fileExists(atPath: url.path))

  for contents in [
    #"{"model":"kept"}"#,
    #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#,
  ] {
    let original = Data(contents.utf8)
    try original.write(to: url)
    #expect(try CodexHooksFile.remove(at: url) == .nothingToRemove)
    #expect(try Data(contentsOf: url) == original)
  }
}

@Test
func unsupportedFilesAreRejectedWithoutBeingRewritten() throws {
  let url = try temporaryHooksURL()
  defer { removeDirectory(of: url) }

  for contents in [
    "not json",
    "[]",
    #"{"hooks":[]}"#,
    #"{"hooks":{"Stop":{"hooks":[]}}}"#,
    #"{"hooks":{"Stop":["say done"]}}"#,
  ] {
    let original = Data(contents.utf8)
    try original.write(to: url)
    #expect(throws: CodexHooksFileError.self) {
      try CodexHooksFile.install(command: adapterCommand, at: url)
    }
    #expect(throws: CodexHooksFileError.self) {
      try CodexHooksFile.remove(at: url)
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

  try CodexHooksFile.install(command: adapterCommand, at: url)

  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
  #expect(commands(in: try hooks(at: target)["Stop"]) == [adapterCommand])

  #expect(try CodexHooksFile.remove(at: url) == .removed)
  let afterRemoval = try FileManager.default.attributesOfItem(atPath: url.path)
  #expect(afterRemoval[.type] as? FileAttributeType == .typeSymbolicLink)
  #expect(try hooks(at: target).isEmpty)
}
