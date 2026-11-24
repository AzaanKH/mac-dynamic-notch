import Foundation

/// A coding agent whose lifecycle hooks NotchRouter can install.
public enum CodingAgent: String, CaseIterable, Sendable {
  case codex
  case claudeCode

  public var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    }
  }

  /// The `notchctl` subcommand its hooks run.
  public var hookCommand: String {
    switch self {
    case .codex: "codex-hook"
    case .claudeCode: "claude-hook"
    }
  }
}

/// Where an agent session runs, read from the environment its hooks inherit.
public struct AgentHookHost: Equatable, Sendable {
  /// The T3 Code thread running the session. T3 Code sets
  /// `T3CODE_THREAD_ID` for every agent process it starts.
  public var t3ThreadID: String?

  public init(t3ThreadID: String? = nil) {
    self.t3ThreadID = t3ThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)
    if self.t3ThreadID?.isEmpty == true { self.t3ThreadID = nil }
  }

  public init(environment: [String: String]) {
    self.init(t3ThreadID: environment["T3CODE_THREAD_ID"])
  }

  /// Threads that T3 Code starts on an agent's behalf (reviews and other
  /// delegated work) have IDs in this namespace. Top-level threads use UUIDs.
  public var isDelegatedT3Thread: Bool {
    t3ThreadID?.hasPrefix("thread:delegated-task:") == true
  }
}

/// One lifecycle hook payload. Codex and Claude Code send the same core
/// fields (`session_id`, `cwd`, `hook_event_name`, …) as JSON on stdin.
public struct AgentHookEvent: Decodable, Sendable {
  public let sessionID: String
  public let turnID: String?
  public let cwd: String
  public let hookEventName: String
  public let toolName: String?
  public let lastAssistantMessage: String?
  public let prompt: String?
  public let taskTitle: String?
  /// Claude Code `Notification` hooks only.
  public let message: String?
  public let notificationType: String?

  public init(
    sessionID: String,
    turnID: String?,
    cwd: String,
    hookEventName: String,
    toolName: String? = nil,
    lastAssistantMessage: String? = nil,
    prompt: String? = nil,
    taskTitle: String? = nil,
    message: String? = nil,
    notificationType: String? = nil
  ) {
    self.sessionID = sessionID
    self.turnID = turnID
    self.cwd = cwd
    self.hookEventName = hookEventName
    self.toolName = toolName
    self.lastAssistantMessage = lastAssistantMessage
    self.prompt = prompt
    self.taskTitle = taskTitle
    self.message = message
    self.notificationType = notificationType
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case turnID = "turn_id"
    case cwd
    case hookEventName = "hook_event_name"
    case toolName = "tool_name"
    case lastAssistantMessage = "last_assistant_message"
    case prompt
    case taskTitle = "task_title"
    case message
    case notificationType = "notification_type"
  }

  /// Maps the hook to an activity update, or `nil` when it should not be
  /// shown. A `cancelled` result is only meaningful while the activity is
  /// still in progress; `AgentHookStateStore` enforces that.
  public func activityEvent(
    agent: CodingAgent = .codex,
    host: AgentHookHost = AgentHookHost()
  ) -> ActivityEventRequest? {
    // Delegated T3 threads are helpers of a thread already shown.
    guard !host.isDelegatedT3Thread else { return nil }

    let state: ActivityState
    let message: String

    let tool = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch hookEventName {
    case "UserPromptSubmit":
      state = .running
      message = "Turn started."
    case "PermissionRequest":
      state = .needsApproval
      if let tool, !tool.isEmpty {
        message = "Waiting for approval to use \(tool)."
      } else {
        message = "Waiting for approval."
      }
    case "Notification" where agent == .claudeCode && notificationType == "permission_prompt":
      state = .needsApproval
      let text = self.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      message = text.isEmpty ? "Waiting for approval." : text
    case "PostToolUse":
      state = .running
      if let tool, !tool.isEmpty {
        message = "Using \(tool)"
      } else {
        message = "Working."
      }
    case "Stop":
      if let response = lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
        !response.isEmpty
      {
        state = .succeeded
        message = response
      } else if agent == .claudeCode {
        // Claude Code may end a turn with tool output only.
        state = .succeeded
        message = "Turn finished."
      } else {
        state = .failed
        message = "Turn ended without a final response."
      }
    case "SessionEnd" where agent == .claudeCode:
      state = .cancelled
      message = "Session ended."
    default:
      return nil
    }

    let workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let workspace = Self.excerpt(workspaceName.isEmpty ? "workspace" : workspaceName, limit: 160)
    let label = [taskTitle, prompt].compactMap { value -> String? in
      let text = value?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      return text?.isEmpty == false ? text : nil
    }.first.map { Self.excerpt($0, limit: 160) }

    return ActivityEventRequest(
      activityID: activityID(agent: agent, host: host),
      source: host.t3ThreadID == nil ? agent.displayName : "\(agent.displayName) · T3 Code",
      title: label ?? "AI work",
      state: state,
      message: Self.excerpt(message, limit: 1_000),
      taskTitle: label,
      workspace: workspace
    )
  }

  /// A T3 thread is one activity across turns and agents, so switching a
  /// thread between Codex and Claude Code updates the same row. Outside T3,
  /// Codex activities are per turn and Claude Code activities per session.
  private func activityID(agent: CodingAgent, host: AgentHookHost) -> String {
    let rawTurnID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let key: String
    if let thread = host.t3ThreadID {
      key = "t3-\(thread)"
    } else if agent == .codex {
      key = "codex-\(rawTurnID?.isEmpty == false ? rawTurnID! : sessionID)"
    } else {
      key = "claude-\(sessionID)"
    }
    return String(key.prefix(128))
  }

  private static func excerpt(_ text: String, limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
  }
}
