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
  let thread = "723a8c12-7e6b-4058-b605-9d5b83905d81"
  let claudeHost = AgentHookHost(
    environment: ["CLAUDE_CODE_ENTRYPOINT": "t3-code", "T3CODE_THREAD_ID": thread], agent: .claudeCode
  )
  let claude = try #require(
    AgentHookEvent(sessionID: "claude-session", turnID: nil, cwd: "/tmp/notch", hookEventName: "Stop", lastAssistantMessage: "Done")
      .activityEvent(agent: .claudeCode, host: claudeHost)
  )
  #expect(claude.activityID == "t3-\(thread)")
  #expect(claude.source == "Claude Code · T3 Code")

  // A Codex process serving one thread joins the same row.
  let codexHost = AgentHookHost(
    environment: ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "T3", "T3CODE_THREAD_ID": thread], agent: .codex
  )
  let codex = try #require(
    AgentHookEvent(sessionID: "codex-session", turnID: "turn-1", cwd: "/tmp/notch", hookEventName: "UserPromptSubmit")
      .activityEvent(agent: .codex, host: codexHost)
  )
  #expect(codex.activityID == claude.activityID, "Switching agents updates the same row")
  #expect(codex.source == "Codex · T3 Code")

  // Threads T3 starts on an agent's behalf, such as reviews, are not shown.
  let delegated = AgentHookHost(
    environment: [
      "CLAUDE_CODE_ENTRYPOINT": "t3-code",
      "T3CODE_THREAD_ID": "thread:delegated-task:command%3Amcp%3Areview",
    ],
    agent: .claudeCode
  )
  #expect(delegated.isDelegatedT3Thread)
  #expect(
    AgentHookEvent(sessionID: "s", turnID: nil, cwd: "/tmp", hookEventName: "UserPromptSubmit")
      .activityEvent(agent: .claudeCode, host: delegated) == nil
  )

  let blank = AgentHookHost(environment: ["CLAUDE_CODE_ENTRYPOINT": "t3-code", "T3CODE_THREAD_ID": "  "], agent: .claudeCode)
  #expect(blank.isT3 && blank.t3ThreadID == nil)
  #expect(AgentHookHost(environment: [:], agent: .claudeCode) == AgentHookHost())
}

@Test
func t3ThreadIDCountsOnlyForAgentsThatT3CodeLaunched() throws {
  // T3 Code's terminals set the thread ID too, so an editor or CLI opened
  // from one inherits it. Those sessions are not that thread.
  let leaked = ["T3CODE_THREAD_ID": "cb56324d-88b3-410e-a9f1-fbfe84265edf", "T3CODE_PROJECT_ROOT": "/p"]
  let vscodeCodex = AgentHookHost(
    environment: leaked.merging(["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "codex_vscode"]) { $1 }, agent: .codex
  )
  let terminalClaude = AgentHookHost(
    environment: leaked.merging(["CLAUDE_CODE_ENTRYPOINT": "cli"]) { $1 }, agent: .claudeCode
  )
  #expect(vscodeCodex == AgentHookHost())
  #expect(terminalClaude == AgentHookHost())
  let turn = AgentHookEvent(sessionID: "s", turnID: "turn-9", cwd: "/tmp/p", hookEventName: "UserPromptSubmit")
  #expect(turn.activityEvent(agent: .codex, host: vscodeCodex)?.activityID == "codex-turn-9")
  #expect(turn.activityEvent(agent: .codex, host: vscodeCodex)?.source == "Codex")

  // T3 Code's shared Codex server serves every thread and has no thread ID:
  // its turns are labelled as T3 Code work and keyed per turn.
  let sharedServer = AgentHookHost(
    environment: ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "T3", "T3CODE_CLI_PATH": "/x/t3"], agent: .codex
  )
  #expect(sharedServer.isT3 && sharedServer.t3ThreadID == nil)
  let event = try #require(turn.activityEvent(agent: .codex, host: sharedServer))
  #expect(event.activityID == "codex-turn-9")
  #expect(event.source == "Codex · T3 Code")
}

@Test
func codexTurnsThatT3DelegatesAreRecognizedByTheirBrief() {
  let t3 = AgentHookHost(isT3: true)
  func prompt(_ text: String, _ name: String = "UserPromptSubmit") -> AgentHookEvent {
    AgentHookEvent(sessionID: "s", turnID: "t", cwd: "/tmp/p", hookEventName: name, prompt: text)
  }
  let brief = prompt(
    "[T3 Code: the agent in T3 thread \"92d36bc1\" sent this message, not the user.] Act as the test sub-agent."
  )
  #expect(brief.startsDelegatedTurn(agent: .codex, host: t3))
  #expect(!brief.startsDelegatedTurn(agent: .codex, host: AgentHookHost()), "Only inside T3 Code")
  #expect(!brief.startsDelegatedTurn(agent: .claudeCode, host: t3), "Claude helpers have their own thread ID")
  #expect(!prompt("Fix the build").startsDelegatedTurn(agent: .codex, host: t3))
}

@Test
func messagesT3CodeSendsForTheUserNeverBecomeTitles() throws {
  let host = AgentHookHost(isT3: true, t3ThreadID: "92d36bc1")
  for notice in [
    "Delegated task node:delegated-task:command%3Amcp%3A68bf%3Adelegate-task%3Asol-147-r2 (Sol review R2: PR #147) [completed]. Use task_status with taskId …",
    "Delegated task node:delegated-task:limit-resume%3Athread%3Adelegated-task (Resume) [completed].",
    "[T3 Code: the agent in T3 thread \"x\" sent this message, not the user.] Please rebase.",
  ] {
    let event = try #require(
      AgentHookEvent(sessionID: "s", turnID: nil, cwd: "/tmp/p", hookEventName: "UserPromptSubmit", prompt: notice)
        .activityEvent(agent: .claudeCode, host: host)
    )
    #expect(event.state == .running, "The agent is working on it")
    // No task title, so NotchRouter keeps the title it already has.
    #expect(event.taskTitle == nil)
  }
}

@Test
func claudeStopFailureWaitsOutUsageLimitsAndFailsOnOtherErrors() throws {
  let input = Data(
    """
    {"session_id":"abc","cwd":"/Users/me/fantasy-draft","hook_event_name":"StopFailure",
     "error":"rate_limit","error_details":"429",
     "last_assistant_message":"You've hit your 5-hour limit · resets 6:30pm (America/Los_Angeles)"}
    """.utf8
  )
  let hook = try JSONDecoder().decode(AgentHookEvent.self, from: input)
  let limited = try #require(hook.activityEvent(agent: .claudeCode))
  #expect(limited.state == .limited)
  #expect(limited.message == "You've hit your 5-hour limit · resets 6:30pm (America/Los_Angeles)")
  #expect(!limited.state.isTerminal, "The thread resumes after the reset")

  let silent = AgentHookEvent(sessionID: "s", turnID: nil, cwd: "/tmp/p", hookEventName: "StopFailure", error: "rate_limit")
  #expect(silent.activityEvent(agent: .claudeCode)?.message == "Waiting for a usage limit to reset.")

  let overloaded = AgentHookEvent(
    sessionID: "s", turnID: nil, cwd: "/tmp/p", hookEventName: "StopFailure",
    lastAssistantMessage: "API Error: Repeated 529 Overloaded errors", error: "overloaded"
  )
  #expect(overloaded.activityEvent(agent: .claudeCode)?.state == .failed)
  #expect(overloaded.activityEvent(agent: .claudeCode)?.message == "API Error: Repeated 529 Overloaded errors")
  #expect(overloaded.activityEvent(agent: .codex) == nil, "Codex has no such hook")
}

@Test
func hiddenTurnsStayHiddenForTheirLaterHooks() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentHookHidden-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = AgentHookStateStore(directory: directory)
  #expect(!store.isHidden("codex-turn-1"))
  try store.hide("codex-turn-1")
  #expect(store.isHidden("codex-turn-1"))
  #expect(!store.isHidden("codex-turn-2"))
  #expect(AgentHookStateStore(directory: directory).isHidden("codex-turn-1"), "Hooks run in separate processes")
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
