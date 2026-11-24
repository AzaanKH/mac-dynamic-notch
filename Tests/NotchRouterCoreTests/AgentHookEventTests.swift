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

  let hook = try JSONDecoder().decode(AgentHookEvent.self, from: input)
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
  let approval = AgentHookEvent(
    sessionID: "session-123",
    turnID: "turn-456",
    cwd: "/tmp/project",
    hookEventName: "PermissionRequest",
    toolName: "Bash"
  ).activityEvent()
  let resumed = AgentHookEvent(
    sessionID: "session-123",
    turnID: "turn-456",
    cwd: "/tmp/project",
    hookEventName: "PostToolUse",
    toolName: "exec_command"
  ).activityEvent()
  let completed = AgentHookEvent(
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
  let ignored = AgentHookEvent(
    sessionID: "session-123",
    turnID: "turn-456",
    cwd: "/tmp/project",
    hookEventName: "SessionStart"
  ).activityEvent()
  let failed = AgentHookEvent(
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
  let hook = AgentHookEvent(
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
  let start = try #require(AgentHookEvent(
    sessionID: "session", turnID: "turn", cwd: "/tmp/project",
    hookEventName: "UserPromptSubmit", prompt: "Fix draft selection"
  ).activityEvent())
  var activity = AIActivity(event: start, now: Date(timeIntervalSince1970: 100))
  activity = try ActivityCoding.makeDecoder().decode(
    AIActivity.self, from: ActivityCoding.makeEncoder().encode(activity)
  )
  let stop = try #require(AgentHookEvent(
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
  let event = try #require(AgentHookEvent(
    sessionID: "session", turnID: "turn", cwd: "/tmp/project",
    hookEventName: "PostToolUse", toolName: "  ", prompt: "  "
  ).activityEvent())
  #expect(event.title == "AI work")
  #expect(event.message == "Working.")
  activity.apply(event)
  #expect(activity.workspace == "project")
}

@Test
func claudeCodeHooksMapToActivityStates() throws {
  func event(_ name: String, tool: String? = nil, last: String? = nil, message: String? = nil, type: String? = nil)
    -> ActivityEventRequest?
  {
    AgentHookEvent(
      sessionID: "claude-session", turnID: nil, cwd: "/Users/me/notch", hookEventName: name,
      toolName: tool, lastAssistantMessage: last, prompt: name == "UserPromptSubmit" ? "Ship it" : nil,
      message: message, notificationType: type
    ).activityEvent(agent: .claudeCode)
  }

  let started = try #require(event("UserPromptSubmit"))
  #expect(started.activityID == "claude-claude-session")
  #expect(started.source == "Claude Code")
  #expect(started.title == "Ship it")
  #expect(started.state == .running)

  #expect(event("PostToolUse", tool: "Bash")?.message == "Using Bash")
  #expect(event("PermissionRequest", tool: "Edit")?.state == .needsApproval)
  let prompt = try #require(
    event("Notification", message: "Claude needs your permission to use Bash", type: "permission_prompt")
  )
  #expect(prompt.state == .needsApproval)
  #expect(prompt.message == "Claude needs your permission to use Bash")
  #expect(event("Notification", message: "Claude is waiting for your input", type: "idle_prompt") == nil)

  #expect(event("Stop", last: "All tests pass.")?.state == .succeeded)
  #expect(event("Stop", last: "All tests pass.")?.message == "All tests pass.")
  // Unlike Codex, a Claude turn without a text reply still finished.
  let silent = try #require(event("Stop"))
  #expect(silent.state == .succeeded)
  #expect(silent.message == "Turn finished.")

  #expect(event("SessionEnd")?.state == .cancelled)
  #expect(event("SubagentStop") == nil)

  // Codex keeps its own rules for the same names.
  let codex = AgentHookEvent(sessionID: "s", turnID: "t", cwd: "/tmp/p", hookEventName: "SessionEnd")
  #expect(codex.activityEvent(agent: .codex) == nil)
}

@Test
func t3CodeThreadsAreOneActivityAcrossAgentsAndSkipDelegatedThreads() throws {
  let host = AgentHookHost(environment: ["T3CODE_THREAD_ID": "723a8c12-7e6b-4058-b605-9d5b83905d81"])
  let codex = try #require(
    AgentHookEvent(sessionID: "codex-session", turnID: "turn-1", cwd: "/tmp/notch", hookEventName: "UserPromptSubmit")
      .activityEvent(agent: .codex, host: host)
  )
  let claude = try #require(
    AgentHookEvent(sessionID: "claude-session", turnID: nil, cwd: "/tmp/notch", hookEventName: "Stop", lastAssistantMessage: "Done")
      .activityEvent(agent: .claudeCode, host: host)
  )
  #expect(codex.activityID == "t3-723a8c12-7e6b-4058-b605-9d5b83905d81")
  #expect(claude.activityID == codex.activityID, "Switching agents updates the same row")
  #expect(codex.source == "Codex · T3 Code")
  #expect(claude.source == "Claude Code · T3 Code")

  // Threads T3 starts on an agent's behalf, such as reviews, are not shown.
  let delegated = AgentHookHost(environment: ["T3CODE_THREAD_ID": "thread:delegated-task:command%3Amcp%3Areview"])
  #expect(delegated.isDelegatedT3Thread)
  #expect(
    AgentHookEvent(sessionID: "s", turnID: nil, cwd: "/tmp", hookEventName: "UserPromptSubmit")
      .activityEvent(agent: .claudeCode, host: delegated) == nil
  )

  #expect(AgentHookHost(environment: ["T3CODE_THREAD_ID": "  "]).t3ThreadID == nil)
  #expect(AgentHookHost(environment: [:]).t3ThreadID == nil)
}

@Test
func claudeHookPayloadDecodesNotificationFields() throws {
  let input = Data(
    """
    {"session_id":"abc","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/app",
     "hook_event_name":"Notification","message":"Claude needs your permission to use Bash",
     "notification_type":"permission_prompt"}
    """.utf8
  )
  let hook = try JSONDecoder().decode(AgentHookEvent.self, from: input)
  #expect(hook.notificationType == "permission_prompt")
  #expect(hook.activityEvent(agent: .claudeCode)?.state == .needsApproval)
}

@Test
func sessionEndCancelsOnlyActivitiesStillInProgress() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentHookState-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = AgentHookStateStore(directory: directory)
  func event(_ name: String, last: String? = nil) throws -> ActivityEventRequest {
    try #require(
      AgentHookEvent(sessionID: "s", turnID: nil, cwd: "/tmp/p", hookEventName: name, lastAssistantMessage: last)
        .activityEvent(agent: .claudeCode)
    )
  }
  let ended = try event("SessionEnd")

  // Never shown: nothing to cancel.
  #expect(try store.shouldPublish(ended) == false)

  // Still running: the session ending cancels it.
  try store.record(try event("UserPromptSubmit"))
  #expect(try store.shouldPublish(ended))

  // Already finished: the result stays.
  try store.record(try event("Stop", last: "Done"))
  #expect(try store.shouldPublish(ended) == false)
}

@Test
func lateBackgroundHooksCannotUndoANewerState() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentHookOrder-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = AgentHookStateStore(directory: directory)
  func event(_ name: String, at seconds: TimeInterval, tool: String? = nil, last: String? = nil) throws
    -> ActivityEventRequest
  {
    var event = try #require(
      AgentHookEvent(
        sessionID: "s", turnID: nil, cwd: "/tmp/p", hookEventName: name, toolName: tool,
        lastAssistantMessage: last
      ).activityEvent(agent: .claudeCode)
    )
    event.timestamp = Date(timeIntervalSince1970: seconds)
    return event
  }

  try store.record(try event("UserPromptSubmit", at: 100))
  let toolUse = try event("PostToolUse", at: 101, tool: "Bash")
  let stop = try event("Stop", at: 102, last: "Done")
  #expect(try store.shouldPublish(stop))
  try store.record(stop)

  // The background PostToolUse hook started first but finished last.
  #expect(try store.shouldPublish(toolUse) == false)
  try store.record(toolUse)
  #expect(
    try store.shouldPublish(try event("SessionEnd", at: 103)) == false,
    "The turn stays finished, so the session ending does not cancel it"
  )

  // The next turn is newer and publishes normally.
  #expect(try store.shouldPublish(try event("UserPromptSubmit", at: 200)))
}

@Test
func heartbeatsAreStillCoalescedAcrossDifferentHookTimes() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentHookHeartbeat-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = AgentHookStateStore(directory: directory)
  var first = try #require(
    AgentHookEvent(sessionID: "s", turnID: nil, cwd: "/tmp/p", hookEventName: "PostToolUse", toolName: "Bash")
      .activityEvent(agent: .claudeCode)
  )
  first.timestamp = Date()
  try store.record(first)
  var repeated = first
  repeated.timestamp = first.timestamp!.addingTimeInterval(1)
  #expect(try store.shouldPublish(repeated) == false)
  #expect(try store.shouldPublish(repeated, now: Date().addingTimeInterval(61)))
}

@Test
func overlappingRecordsNeverReplaceANewerPublication() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentHookRace-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  // Separate store values open separate lock descriptors, as separate hook
  // processes would.
  func event(_ session: String, _ name: String, at seconds: TimeInterval, last: String? = nil) throws
    -> ActivityEventRequest
  {
    var event = try #require(
      AgentHookEvent(
        sessionID: session, turnID: nil, cwd: "/tmp/p", hookEventName: name, toolName: "Bash",
        lastAssistantMessage: last
      ).activityEvent(agent: .claudeCode)
    )
    event.timestamp = Date(timeIntervalSince1970: seconds)
    return event
  }

  var cancelledFinishedTurns = 0
  for iteration in 0..<200 {
    let session = "race-\(iteration)"
    let late = try event(session, "PostToolUse", at: 101)
    let stop = try event(session, "Stop", at: 102, last: "Done")
    DispatchQueue.concurrentPerform(iterations: 2) { index in
      try? AgentHookStateStore(directory: directory).record(index == 0 ? late : stop)
    }
    if try AgentHookStateStore(directory: directory).shouldPublish(try event(session, "SessionEnd", at: 103)) {
      cancelledFinishedTurns += 1
    }
  }
  #expect(cancelledFinishedTurns == 0)
}
