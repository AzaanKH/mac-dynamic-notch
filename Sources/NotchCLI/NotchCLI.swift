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
      await agentHook(.codex)
    case "claude-hook":
      await agentHook(.claudeCode)
    case "install-codex-hooks":
      try installHooks(.codex)
    case "install-claude-hooks":
      try installHooks(.claudeCode)
    case "remove-codex-hooks":
      try removeHooks(.codex)
    case "remove-claude-hooks":
      try removeHooks(.claudeCode)
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
    let options = try parseOptions(
      arguments,
      allowed: [
        "id", "source", "title", "state", "message", "progress", "action-url",
        "task-title", "workspace",
      ]
    )
    guard let activityID = options["id"],
      let source = options["source"],
      let title = options["title"],
      let stateValue = options["state"]
    else {
      throw CLIError.missingSendArguments
    }
    guard let state = ActivityState(rawValue: stateValue) else {
      throw CLIError.invalidState(stateValue)
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

    let actionURL: URL?
    if let rawActionURL = options["action-url"] {
      guard let url = URL(string: rawActionURL), url.scheme != nil else {
        throw CLIError.invalidActionURL(rawActionURL)
      }
      actionURL = url
    } else {
      actionURL = nil
    }

    let event = ActivityEventRequest(
      activityID: activityID,
      source: source,
      title: title,
      state: state,
      message: options["message"],
      progress: progress,
      actionURL: actionURL,
      taskTitle: options["task-title"],
      workspace: options["workspace"]
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

  private static func agentHook(_ agent: CodingAgent) async {
    // Background hooks can be delivered out of order. Stamping each event
    // with the moment its hook started lets NotchRouter and the state store
    // ignore an update that arrives after a newer one.
    let startedAt = Date()
    do {
      let input = FileHandle.standardInput.readDataToEndOfFile()
      let hook = try JSONDecoder().decode(AgentHookEvent.self, from: input)
      let host = AgentHookHost(environment: ProcessInfo.processInfo.environment, agent: agent)
      let stateStore = AgentHookStateStore()
      // A delegated helper's work already shows on the thread that started it.
      let activityID = hook.activityID(agent: agent, host: host)
      if hook.startsDelegatedTurn(agent: agent, host: host) {
        try stateStore.hide(activityID)
        return
      }
      guard !stateStore.isHidden(activityID),
        var event = hook.activityEvent(agent: agent, host: host)
      else { return }
      event.timestamp = startedAt

      guard try stateStore.shouldPublish(event) else {
        return
      }

      let body = try ActivityCoding.makeEncoder().encode(event)
      _ = try await request(
        path: "/v1/activities",
        method: "POST",
        body: body,
        timeout: 1
      )
      try stateStore.record(event)
    } catch {
      // Hooks are advisory. A closed NotchRouter app must never interrupt an agent.
    }
  }

  private static func hooksFile(_ agent: CodingAgent) -> AgentHooksFile {
    switch agent {
    case .codex: .codex
    case .claudeCode: .claudeCode
    }
  }

  private static func installHooks(_ agent: CodingAgent) throws {
    let file = hooksFile(agent)
    let executablePath = try installAdapterExecutable()
    try file.install(command: file.command(helperPath: executablePath))

    print("Installed \(agent.displayName) lifecycle hooks in \(file.defaultURL.path)")
    switch agent {
    case .codex:
      print("Restart T3 Code, then review and trust the new hooks with /hooks.")
    case .claudeCode:
      print("New Claude Code sessions, including T3 Code's Claude threads, use them.")
      print("Already-running sessions pick them up after you review them with /hooks.")
    }
  }

  private static func installAdapterExecutable() throws -> String {
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

  private static func removeHooks(_ agent: CodingAgent) throws {
    let file = hooksFile(agent)
    let path = file.defaultURL.path
    switch try file.remove() {
    case .noFile:
      print("\(path) does not exist; nothing to remove.")
    case .nothingToRemove:
      print("No NotchRouter hooks are installed in \(path); nothing to remove.")
    case .removed:
      print("Removed NotchRouter's \(agent.displayName) lifecycle hooks from \(path)")
    }
  }

  private static func installBrowserExtension() throws {
    try BrowserExtensionInstaller.install()
    print("Installed the browser bridge for Chrome, Edge, Brave, Chromium, Firefox, and Zen.")
    print("In Zen or Firefox, use about:debugging > This Firefox > Load Temporary Add-on and select manifest.json.")
    print("Extension folder: \(BrowserExtensionInstaller.extensionDirectory.path)")
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
    let response = try await LocalAPIClient.request(
      path: path, method: method, body: body,
      token: authenticated ? IntegrationToken.loadOrCreate() : nil, timeout: timeout
    )
    guard (200..<300).contains(response.status) else {
      let message = String(data: response.body, encoding: .utf8) ?? "Unknown server error"
      throw CLIError.server(status: response.status, message: message)
    }
    return response.body
  }

  private static func parseOptions(
    _ arguments: [String],
    allowed: Set<String>
  ) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--"), index + 1 < arguments.count else {
        throw CLIError.invalidOption(argument)
      }
      let name = String(argument.dropFirst(2))
      // A misspelled or repeated option would otherwise be dropped silently.
      guard allowed.contains(name) else {
        throw CLIError.unknownOption(argument)
      }
      guard result[name] == nil else {
        throw CLIError.repeatedOption(argument)
      }
      result[name] = arguments[index + 1]
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
        notchctl install-claude-hooks
        notchctl remove-claude-hooks
        notchctl install-browser-extension
        notchctl remove-browser-extension
        notchctl browser-extension-status

      AGENT ADAPTERS
        codex-hook and claude-hook read a lifecycle hook from standard input.
        install-codex-hooks adds user-level hooks for Codex and T3 Code's
        Codex threads. install-claude-hooks adds them to Claude Code's user
        settings, covering the Claude Code CLI and T3 Code's Claude threads.
        Each T3 Code thread is one activity, whichever agent it uses.

      STATES
        queued, running, needs_approval, limited, stale, succeeded, failed, cancelled

      SEND OPTIONS
        --message TEXT
        --progress 0.0...1.0
        --action-url URL
        --task-title TEXT   shown in place of the title and kept across updates
        --workspace NAME

      HEARTBEATS
        Re-send an identical nonterminal activity at least once a minute.
      """
    )
  }
}

private enum CLIError: LocalizedError {
  case unknownCommand(String)
  case missingSendArguments
  case invalidProgress(String)
  case invalidState(String)
  case invalidActionURL(String)
  case invalidOption(String)
  case unknownOption(String)
  case repeatedOption(String)
  case invalidResponse
  case server(status: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .unknownCommand(let command):
      "Unknown command '\(command)'. Run notchctl help."
    case .missingSendArguments:
      "send requires --id, --source, --title, and --state."
    case .invalidProgress(let value):
      "'\(value)' is not a valid progress value."
    case .invalidState(let value):
      "'\(value)' is not a valid state. Use "
        + ActivityState.allCases.map(\.rawValue).joined(separator: ", ") + "."
    case .invalidActionURL(let value):
      "'\(value)' is not a valid action URL."
    case .invalidOption(let option):
      "Invalid option near '\(option)'. Options require a value."
    case .unknownOption(let option):
      "Unknown option '\(option)'. Run notchctl help."
    case .repeatedOption(let option):
      "Option '\(option)' was given more than once."
    case .invalidResponse:
      "NotchRouter returned an invalid HTTP response."
    case .server(let status, let message):
      "NotchRouter returned HTTP \(status): \(message)"
    }
  }
}
