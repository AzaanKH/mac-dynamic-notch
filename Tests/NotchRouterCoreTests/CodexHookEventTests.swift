import Foundation
import NotchRouterCore
import Testing

@Test
func codexHookUsesPromptAsTaskTitle() throws {
  let input = Data(
    """
    {
      "session_id": "session-123",
      "turn_id": "turn-456",
      "cwd": "/Users/example/fantasy-draft",
      "hook_event_name": "UserPromptSubmit",
      "prompt": "Fix draft selection handling"
    }
    """.utf8
  )

  let hook = try JSONDecoder().decode(CodexHookEvent.self, from: input)
  let event = try #require(hook.activityEvent())

  #expect(event.activityID == "codex-turn-456")
  #expect(event.source == "Codex")
  #expect(event.title == "Fix draft selection handling")
  #expect(event.workspace == "fantasy-draft")
  #expect(event.taskTitle == "Fix draft selection handling")
  #expect(event.state == .running)
  #expect(event.message == "Turn started.")
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
    hookEventName: "PostToolUse",
    toolName: "exec_command"
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
  #expect(resumed?.message == "Using exec_command")
  #expect(completed?.state == .succeeded)
  #expect(completed?.message == "Done")
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

@Test
func codexHookBoundsContentAndPrefersTaskLabel() throws {
  let hook = CodexHookEvent(
    sessionID: "session", turnID: "turn", cwd: "/tmp/project",
    hookEventName: "Stop", lastAssistantMessage: String(repeating: "👩🏽‍💻", count: 1_100),
    prompt: "Prompt fallback", taskTitle: "  Fix\n" + String(repeating: "x", count: 200)
  )
  let event = try #require(hook.activityEvent()).validated()
  #expect(event.title.hasPrefix("Fix "))
  #expect(event.title.count == 160)
  #expect(event.message?.count == 1_000)
  #expect(event.message?.hasSuffix("…") == true)
  let json = try #require(
    JSONSerialization.jsonObject(with: ActivityCoding.makeEncoder().encode(event)) as? [String: Any]
  )
  #expect(json["task_title"] as? String == event.title)
  #expect(json["workspace"] as? String == "project")
  #expect(json["message"] as? String == event.message)
}

@Test
func codexTaskSurvivesLaterHooksAndPersistence() throws {
  let start = try #require(CodexHookEvent(
    sessionID: "session", turnID: "turn", cwd: "/tmp/project",
    hookEventName: "UserPromptSubmit", prompt: "Fix draft selection"
  ).activityEvent())
  var activity = AIActivity(event: start, now: Date(timeIntervalSince1970: 100))
  activity = try ActivityCoding.makeDecoder().decode(
    AIActivity.self, from: ActivityCoding.makeEncoder().encode(activity)
  )
  let stop = try #require(CodexHookEvent(
    sessionID: "session", turnID: "turn", cwd: "/tmp/project",
    hookEventName: "Stop", lastAssistantMessage: "Fixed duplicate selections. Tests passed."
  ).activityEvent())
  activity.apply(stop, now: Date(timeIntervalSince1970: 110))
  #expect(activity.title == "Fix draft selection")
  #expect(activity.workspace == "project")
  #expect(activity.message == "Fixed duplicate selections. Tests passed.")
  #expect(activity.history.map(\.message) == ["Turn started.", "Fixed duplicate selections. Tests passed."])
}

@Test
func legacyActivityAcceptsNewDetailsAndHookFallbacks() throws {
  let data = Data("""
    {"id":"codex-turn","source":"Codex","title":"AI work in project",
     "state":"running","started_at":"2026-01-01T00:00:00Z",
     "updated_at":"2026-01-01T00:00:00Z","history":[]}
    """.utf8)
  var activity = try ActivityCoding.makeDecoder().decode(AIActivity.self, from: data)
  #expect(activity.workspace == nil)
  let event = try #require(CodexHookEvent(
    sessionID: "session", turnID: "turn", cwd: "/tmp/project",
    hookEventName: "PostToolUse", toolName: "  ", prompt: "  "
  ).activityEvent())
  #expect(event.title == "AI work")
  #expect(event.message == "Working.")
  activity.apply(event)
  #expect(activity.workspace == "project")
}
