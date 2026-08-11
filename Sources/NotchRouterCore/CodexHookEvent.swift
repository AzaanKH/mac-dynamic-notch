import Foundation

public struct CodexHookEvent: Decodable, Sendable {
  public let sessionID: String
  public let turnID: String?
  public let cwd: String
  public let hookEventName: String
  public let toolName: String?
  public let lastAssistantMessage: String?

  public init(
    sessionID: String,
    turnID: String?,
    cwd: String,
    hookEventName: String,
    toolName: String? = nil,
    lastAssistantMessage: String? = nil
  ) {
    self.sessionID = sessionID
    self.turnID = turnID
    self.cwd = cwd
    self.hookEventName = hookEventName
    self.toolName = toolName
    self.lastAssistantMessage = lastAssistantMessage
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case turnID = "turn_id"
    case cwd
    case hookEventName = "hook_event_name"
    case toolName = "tool_name"
    case lastAssistantMessage = "last_assistant_message"
  }

  public func activityEvent() -> ActivityEventRequest? {
    let state: ActivityState
    let message: String

    switch hookEventName {
    case "UserPromptSubmit":
      state = .running
      message = "Turn started."
    case "PermissionRequest":
      state = .needsApproval
      if let toolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
        !toolName.isEmpty
      {
        message = "Waiting for approval to use \(toolName)."
      } else {
        message = "Waiting for approval."
      }
    case "PostToolUse":
      state = .running
      message = "Working."
    case "Stop":
      if lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        state = .succeeded
        message = "Turn completed."
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
    let workspace = workspaceName.isEmpty ? "workspace" : workspaceName

    return ActivityEventRequest(
      activityID: activityID,
      source: "Codex",
      title: "AI work in \(workspace)",
      state: state,
      message: message
    )
  }
}
