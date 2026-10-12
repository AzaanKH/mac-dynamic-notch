import Foundation

public struct CodexHookEvent: Decodable, Sendable {
  public let sessionID: String
  public let turnID: String?
  public let cwd: String
  public let hookEventName: String
  public let toolName: String?
  public let lastAssistantMessage: String?
  public let prompt: String?
  public let taskTitle: String?

  public init(
    sessionID: String,
    turnID: String?,
    cwd: String,
    hookEventName: String,
    toolName: String? = nil,
    lastAssistantMessage: String? = nil,
    prompt: String? = nil,
    taskTitle: String? = nil
  ) {
    self.sessionID = sessionID
    self.turnID = turnID
    self.cwd = cwd
    self.hookEventName = hookEventName
    self.toolName = toolName
    self.lastAssistantMessage = lastAssistantMessage
    self.prompt = prompt
    self.taskTitle = taskTitle
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
  }

  public func activityEvent() -> ActivityEventRequest? {
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
      } else {
        state = .failed
        message = "Turn ended without a final response."
      }
    default:
      return nil
    }

    let rawID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let stableID = rawID?.isEmpty == false ? rawID! : sessionID
    let activityID = String("codex-\(stableID)".prefix(128))
    let workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let workspace = Self.excerpt(workspaceName.isEmpty ? "workspace" : workspaceName, limit: 160)
    let label = [taskTitle, prompt].compactMap { value -> String? in
      let text = value?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      return text?.isEmpty == false ? text : nil
    }.first.map { Self.excerpt($0, limit: 160) }

    return ActivityEventRequest(
      activityID: activityID,
      source: "Codex",
      title: label ?? "AI work",
      state: state,
      message: Self.excerpt(message, limit: 1_000),
      taskTitle: label,
      workspace: workspace
    )
  }

  private static func excerpt(_ text: String, limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
  }
}
