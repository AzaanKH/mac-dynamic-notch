import Foundation
import NotchRouterCore
import Testing

@Test
func codexHookMapsTurnLifecycleWithoutForwardingContent() throws {
  let input = Data(
    """
    {
      "session_id": "session-123",
      "turn_id": "turn-456",
      "cwd": "/Users/example/fantasy-draft",
      "hook_event_name": "UserPromptSubmit",
      "prompt": "A private prompt that must not leave Codex"
    }
    """.utf8
  )

  let hook = try JSONDecoder().decode(CodexHookEvent.self, from: input)
  let event = try #require(hook.activityEvent())

  #expect(event.activityID == "codex-turn-456")
  #expect(event.source == "Codex")
  #expect(event.title == "AI work in fantasy-draft")
  #expect(event.state == .running)
  #expect(event.message == "Turn started.")
  #expect(event.message?.contains("private prompt") == false)
}

@Test
func codexHookMapsApprovalResumeAndCompletionStates() throws {
  let approval = CodexHookEvent(
    sessionID: "session-123",
    turnID: "turn-456",
    cwd: "/tmp/project",
    hookEventName: "PermissionRequest",
    toolName: "Bash"
  ).activityEvent()
  let resumed = CodexHookEvent(
    sessionID: "session-123",
    turnID: "turn-456",
    cwd: "/tmp/project",
    hookEventName: "PostToolUse"
  ).activityEvent()
  let completed = CodexHookEvent(
    sessionID: "session-123",
    turnID: "turn-456",
    cwd: "/tmp/project",
    hookEventName: "Stop",
    lastAssistantMessage: "Done"
  ).activityEvent()

  #expect(approval?.state == .needsApproval)
  #expect(approval?.message == "Waiting for approval to use Bash.")
  #expect(resumed?.state == .running)
  #expect(completed?.state == .succeeded)
}

@Test
func codexHookIgnoresUnsupportedEventsAndFlagsMissingFinalResponse() {
  let ignored = CodexHookEvent(
    sessionID: "session-123",
    turnID: "turn-456",
    cwd: "/tmp/project",
    hookEventName: "SessionStart"
  ).activityEvent()
  let failed = CodexHookEvent(
    sessionID: "session-123",
    turnID: "turn-456",
    cwd: "/tmp/project",
    hookEventName: "Stop",
    lastAssistantMessage: nil
  ).activityEvent()

  #expect(ignored == nil)
  #expect(failed?.state == .failed)
}
