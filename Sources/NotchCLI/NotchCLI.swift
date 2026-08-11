import CryptoKit
import Foundation
import NotchRouterCore

@main
enum NotchCLI {
  static func main() async {
    do {
      try await run(arguments: Array(CommandLine.arguments.dropFirst()))
    } catch {
      FileHandle.standardError.write(
        Data("notchctl: \(error.localizedDescription)\n".utf8)
      )
      exit(1)
    }
  }

  private static func run(arguments: [String]) async throws {
    guard let command = arguments.first else {
      printHelp()
      return
    }

    switch command {
    case "send":
      try await send(arguments: Array(arguments.dropFirst()))
    case "demo":
      try await demo()
    case "list":
      try await list()
    case "token":
      print(try IntegrationToken.loadOrCreate())
    case "health":
      try await health()
    case "codex-hook":
      await codexHook()
    case "install-codex-hooks":
      try installCodexHooks()
    case "remove-codex-hooks":
      try removeCodexHooks()
    case "install-browser-extension":
      try installBrowserExtension()
    case "remove-browser-extension":
      try removeBrowserExtension()
    case "browser-extension-status":
      print(BrowserExtensionInstaller.isInstalled ? "installed" : "not installed")
    case "help", "--help", "-h":
      printHelp()
    default:
      throw CLIError.unknownCommand(command)
    }
  }

  private static func send(arguments: [String]) async throws {
    let options = try parseOptions(arguments)
    guard let activityID = options["id"],
      let source = options["source"],
      let title = options["title"],
      let stateValue = options["state"],
      let state = ActivityState(rawValue: stateValue)
    else {
      throw CLIError.missingSendArguments
    }

    let progress: Double?
    if let rawProgress = options["progress"] {
      guard let value = Double(rawProgress) else {
        throw CLIError.invalidProgress(rawProgress)
      }
      progress = value
    } else {
      progress = nil
    }

    let event = ActivityEventRequest(
      activityID: activityID,
      source: source,
      title: title,
      state: state,
      message: options["message"],
      progress: progress,
      actionURL: options["action-url"].flatMap(URL.init(string:))
    )
    let body = try ActivityCoding.makeEncoder().encode(event)
    let response = try await request(
      path: "/v1/activities",
      method: "POST",
      body: body
    )
    print(String(data: response, encoding: .utf8) ?? "Accepted")
  }

  private static func demo() async throws {
    let id = "demo-\(Int(Date().timeIntervalSince1970))"
    let event = ActivityEventRequest(
      activityID: id,
      source: "Demo Agent",
      title: "Review the checkout flow",
      state: .needsApproval,
      message: "The agent changed three files and is waiting for approval.",
      progress: 0.76,
      actionURL: URL(string: "https://example.com/review")
    )
    let response = try await request(
      path: "/v1/activities",
      method: "POST",
      body: ActivityCoding.makeEncoder().encode(event)
    )
    print(String(data: response, encoding: .utf8) ?? "Accepted")
  }

  private static func list() async throws {
    let data = try await request(path: "/v1/activities")
    if let object = try? JSONSerialization.jsonObject(with: data),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
      )
    {
      print(String(data: pretty, encoding: .utf8) ?? "[]")
    } else {
      print(String(data: data, encoding: .utf8) ?? "[]")
    }
  }

  private static func health() async throws {
    let data = try await request(path: "/v1/health", authenticated: false)
    print(String(data: data, encoding: .utf8) ?? "OK")
  }

  private static func codexHook() async {
    do {
      let input = FileHandle.standardInput.readDataToEndOfFile()
      let hook = try JSONDecoder().decode(CodexHookEvent.self, from: input)
      guard let event = hook.activityEvent() else { return }

      let stateStore = CodexHookStateStore()
      guard try stateStore.shouldPublish(event.state, for: event.activityID) else {
        return
      }

      let body = try ActivityCoding.makeEncoder().encode(event)
      _ = try await request(
        path: "/v1/activities",
        method: "POST",
        body: body,
        timeout: 1
      )
      try stateStore.record(event.state, for: event.activityID)
    } catch {
      // Hooks are advisory. A closed NotchRouter app must never interrupt Codex.
    }
  }

  private static func installCodexHooks() throws {
    let executablePath = try installCodexAdapterExecutable()
    let command = "\(shellQuote(executablePath)) codex-hook"
    let codexDirectory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true)
    let hooksURL = codexDirectory.appendingPathComponent("hooks.json")

    try FileManager.default.createDirectory(
      at: codexDirectory,
      withIntermediateDirectories: true
    )

    var root: [String: Any] = [
      "description": "Publishes privacy-preserving Codex lifecycle state to NotchRouter."
    ]
    if FileManager.default.fileExists(atPath: hooksURL.path) {
      let data = try Data(contentsOf: hooksURL)
      guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CLIError.invalidHooksFile
      }
      root = existing
    }

    let hooksValue = root["hooks"]
    guard hooksValue == nil || hooksValue is [String: Any] else {
      throw CLIError.invalidHooksFile
    }
    var hooks = hooksValue as? [String: Any] ?? [:]
    for eventName in ["UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"] {
      let groupsValue = hooks[eventName]
      guard groupsValue == nil || groupsValue is [[String: Any]] else {
        throw CLIError.invalidHooksFile
      }
      var groups = removingCodexAdapterHandlers(
        from: groupsValue as? [[String: Any]] ?? []
      )
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

    try writeHooks(root, to: hooksURL)

    print("Installed Codex lifecycle hooks in \(hooksURL.path)")
    print("Restart T3 Code, then review and trust the new hooks with /hooks.")
  }

  private static func installCodexAdapterExecutable() throws -> String {
    let sourceURL =
      Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let binDirectory = AppPaths.applicationSupportDirectory
      .appendingPathComponent("bin", isDirectory: true)
    let destinationURL = binDirectory.appendingPathComponent("notchctl")

    try FileManager.default.createDirectory(
      at: binDirectory,
      withIntermediateDirectories: true
    )
    if sourceURL != destinationURL {
      let executable = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
      try executable.write(to: destinationURL, options: [.atomic])
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: destinationURL.path
    )
    return destinationURL.path
  }

  private static func removeCodexHooks() throws {
    let hooksURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("hooks.json")
    guard FileManager.default.fileExists(atPath: hooksURL.path) else {
      print("No Codex hooks file exists; nothing to remove.")
      return
    }

    let data = try Data(contentsOf: hooksURL)
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var hooks = root["hooks"] as? [String: Any]
    else {
      throw CLIError.invalidHooksFile
    }

    for eventName in ["UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"] {
      guard let groups = hooks[eventName] as? [[String: Any]] else { continue }
      let filtered = removingCodexAdapterHandlers(from: groups)
      if filtered.isEmpty {
        hooks.removeValue(forKey: eventName)
      } else {
        hooks[eventName] = filtered
      }
    }
    root["hooks"] = hooks
    try writeHooks(root, to: hooksURL)
    print("Removed NotchRouter's Codex lifecycle hooks from \(hooksURL.path)")
  }

  private static func installBrowserExtension() throws {
    try BrowserExtensionInstaller.install()
    print("Installed the browser bridge for Chrome, Edge, Brave, and Chromium.")
    print("Load the unpacked extension from \(BrowserExtensionInstaller.extensionDirectory.path)")
  }

  private static func removeBrowserExtension() throws {
    try BrowserExtensionInstaller.remove()
    print("Removed the browser bridge and unpacked extension files.")
  }

  private static func request(
    path: String,
    method: String = "GET",
    body: Data? = nil,
    authenticated: Bool = true,
    timeout: TimeInterval = 4
  ) async throws -> Data {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:48271\(path)")!
    )
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = timeout
    if body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if authenticated {
      request.setValue(
        "Bearer \(try IntegrationToken.loadOrCreate())",
        forHTTPHeaderField: "Authorization"
      )
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw CLIError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown server error"
      throw CLIError.server(status: response.statusCode, message: message)
    }
    return data
  }

  private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--"), index + 1 < arguments.count else {
        throw CLIError.invalidOption(argument)
      }
      result[String(argument.dropFirst(2))] = arguments[index + 1]
      index += 2
    }
    return result
  }

  private static func printHelp() {
    print(
      """
      notchctl — publish AI activity to NotchRouter

      USAGE
        notchctl send --id ID --source APP --title TITLE --state STATE [options]
        notchctl demo
        notchctl list
        notchctl health
        notchctl token
        notchctl install-codex-hooks
        notchctl remove-codex-hooks
        notchctl install-browser-extension
        notchctl remove-browser-extension

      CODEX ADAPTER
        codex-hook reads a Codex lifecycle hook from standard input.
        install-codex-hooks adds user-level hooks for T3 Code and Codex.

      STATES
        queued, running, needs_approval, stale, succeeded, failed, cancelled

      SEND OPTIONS
        --message TEXT
        --progress 0.0...1.0
        --action-url URL

      HEARTBEATS
        Re-send an identical nonterminal activity at least once a minute.
      """
    )
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private static func removingCodexAdapterHandlers(
    from groups: [[String: Any]]
  ) -> [[String: Any]] {
    groups.compactMap { group in
      guard let handlers = group["hooks"] as? [[String: Any]] else {
        return group
      }
      let remainingHandlers = handlers.filter { handler in
        guard let command = handler["command"] as? String else { return true }
        return !(command.contains("notchctl") && command.hasSuffix(" codex-hook"))
      }
      guard !remainingHandlers.isEmpty else { return nil }
      var updatedGroup = group
      updatedGroup["hooks"] = remainingHandlers
      return updatedGroup
    }
  }

  private static func writeHooks(_ root: [String: Any], to url: URL) throws {
    var data = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys]
    )
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }
}

private struct CodexHookStateStore {
  private let directory = AppPaths.applicationSupportDirectory
    .appendingPathComponent("codex-adapter-state", isDirectory: true)

  func recordedState(for activityID: String) throws -> ActivityState? {
    cleanupExpiredFiles()
    guard
      let rawValue = try? String(
        contentsOf: stateURL(for: activityID),
        encoding: .utf8
      ).trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return nil
    }
    return ActivityState(rawValue: rawValue)
  }

  func shouldPublish(
    _ state: ActivityState,
    for activityID: String,
    now: Date = Date()
  ) throws -> Bool {
    guard try recordedState(for: activityID) == state else {
      return true
    }
    guard !state.isTerminal else {
      return false
    }
    guard
      let values = try? stateURL(for: activityID).resourceValues(
        forKeys: [.contentModificationDateKey]
      ),
      let lastPublishedAt = values.contentModificationDate
    else {
      return true
    }
    return now.timeIntervalSince(lastPublishedAt) >= ActivityLiveness.heartbeatInterval
  }

  func record(_ state: ActivityState, for activityID: String) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let url = stateURL(for: activityID)
    try Data("\(state.rawValue)\n".utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  private func stateURL(for activityID: String) -> URL {
    let digest = SHA256.hash(data: Data(activityID.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return directory.appendingPathComponent("\(digest).state")
  }

  private func cleanupExpiredFiles() {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }
    let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    for file in files where file.pathExtension == "state" {
      guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
        let modifiedAt = values.contentModificationDate,
        modifiedAt < cutoff
      else {
        continue
      }
      try? FileManager.default.removeItem(at: file)
    }
  }
}

private enum CLIError: LocalizedError {
  case unknownCommand(String)
  case missingSendArguments
  case invalidProgress(String)
  case invalidOption(String)
  case invalidResponse
  case invalidHooksFile
  case server(status: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .unknownCommand(let command):
      "Unknown command '\(command)'. Run notchctl help."
    case .missingSendArguments:
      "send requires --id, --source, --title, and --state."
    case .invalidProgress(let value):
      "'\(value)' is not a valid progress value."
    case .invalidOption(let option):
      "Invalid option near '\(option)'. Options require a value."
    case .invalidResponse:
      "NotchRouter returned an invalid HTTP response."
    case .invalidHooksFile:
      "~/.codex/hooks.json is not a JSON object."
    case .server(let status, let message):
      "NotchRouter returned HTTP \(status): \(message)"
    }
  }
}
