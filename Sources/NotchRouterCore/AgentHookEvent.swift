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
  /// T3 Code started the agent process.
  public var isT3: Bool
  /// The T3 Code thread running the session, when the process serves one
  /// thread. T3 Code's shared Codex server serves many, so it has none.
  public var t3ThreadID: String?

  public init(isT3: Bool = false, t3ThreadID: String? = nil) {
    let thread = t3ThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.t3ThreadID = thread?.isEmpty == false ? thread : nil
    self.isT3 = isT3 || self.t3ThreadID != nil
  }

  /// `T3CODE_THREAD_ID` alone is not proof: T3 Code's terminals set it too,
  /// so an editor or CLI opened from one inherits it. Only the launch marker
  /// each agent gets from T3 Code identifies a T3 Code session.
  public init(environment: [String: String], agent: CodingAgent) {
    let isT3 =
      switch agent {
      case .claudeCode: environment["CLAUDE_CODE_ENTRYPOINT"] == "t3-code"
      case .codex: environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == "T3"
      }
    self.init(isT3: isT3, t3ThreadID: isT3 ? environment["T3CODE_THREAD_ID"] : nil)
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
  /// Claude Code `StopFailure` hooks only: `rate_limit`, `server_error`, …
  public let error: String?

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
    notificationType: String? = nil,
    error: String? = nil
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
    self.error = error
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
    case error
  }

  /// T3 Code marks messages that one agent sends another, such as the brief
  /// for a delegated task, so they are not mistaken for the user's.
  private static let agentMessagePrefix = "[T3 Code: the agent in T3 thread "
  /// T3 Code tells a thread when its delegated task finishes or resumes.
  private static let delegationNoticePrefix = "Delegated task node:delegated-task:"

  /// T3 Code's shared Codex server does not say which thread a turn belongs
  /// to, so a delegated helper is recognized by the brief that starts it.
  /// Its later hooks carry no prompt; `AgentHookStateStore` remembers it.
  public func startsDelegatedTurn(agent: CodingAgent, host: AgentHookHost) -> Bool {
    agent == .codex && host.isT3 && hookEventName == "UserPromptSubmit"
      && prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix(Self.agentMessagePrefix) == true
  }

  /// Text that T3 Code sent in place of the user does not describe the work,
  /// so it never becomes the activity title.
  private static func isT3Notice(_ text: String) -> Bool {
    text.hasPrefix(agentMessagePrefix) || text.hasPrefix(delegationNoticePrefix)
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
    case "StopFailure" where agent == .claudeCode:
      // Claude Code runs this instead of Stop when an API error ends the
      // turn. Its last message is the error, such as "You've hit your
      // 5-hour limit · resets 6:30pm".
      let text = lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if error == "rate_limit" {
        state = .limited
        message = text.isEmpty ? "Waiting for a usage limit to reset." : text
      } else {
        state = .failed
        message = text.isEmpty ? "The turn ended with an API error." : text
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
      guard let text, !text.isEmpty, !Self.isT3Notice(text) else { return nil }
      return text
    }.first.map { Self.excerpt($0, limit: 160) }

    return ActivityEventRequest(
      activityID: activityID(agent: agent, host: host),
      source: host.isT3 ? "\(agent.displayName) · T3 Code" : agent.displayName,
      title: label ?? "AI work",
      state: state,
      message: Self.excerpt(message, limit: 1_000),
      taskTitle: label,
      workspace: workspace
    )
  }

  /// A T3 thread is one activity across turns and agents, so switching a
  /// thread between Codex and Claude Code updates the same row. Otherwise,
  /// Codex activities are per turn and Claude Code activities per session.
  public func activityID(agent: CodingAgent, host: AgentHookHost) -> String {
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
