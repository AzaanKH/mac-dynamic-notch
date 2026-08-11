import Foundation
import NotchRouterCore
import Testing

@Test
func activityAccumulatesStateHistory() throws {
  let start = Date(timeIntervalSince1970: 1_000)
  var activity = AIActivity(
    event: ActivityEventRequest(
      activityID: "agent-1",
      source: "Codex",
      title: "Refactor settings",
      state: .running,
      message: "Inspecting the project",
      progress: 0.2,
      timestamp: start
    )
  )

  activity.apply(
    ActivityEventRequest(
      activityID: "agent-1",
      source: "Codex",
      title: "Refactor settings",
      state: .needsApproval,
      message: "Ready for review",
      progress: 0.9,
      timestamp: start.addingTimeInterval(10)
    )
  )

  #expect(activity.state == .needsApproval)
  #expect(activity.history.count == 2)
  #expect(activity.progress == 0.9)
  #expect(activity.message == "Ready for review")
}

@Test
func delayedEventsDoNotRegressCurrentState() throws {
  let start = Date(timeIntervalSince1970: 1_000)
  var activity = AIActivity(
    event: ActivityEventRequest(
      activityID: "agent-delayed",
      source: "Build Agent",
      title: "Run release build",
      state: .succeeded,
      message: "Release build passed",
      timestamp: start.addingTimeInterval(20)
    )
  )

  activity.apply(
    ActivityEventRequest(
      activityID: "agent-delayed",
      source: "Build Agent",
      title: "Run release build",
      state: .running,
      message: "Compiling",
      timestamp: start
    )
  )

  #expect(activity.state == .succeeded)
  #expect(activity.message == "Release build passed")
  #expect(activity.history.map(\.state) == [.running, .succeeded])
}

@Test
func validationClampsProgressAndRejectsEmptyIdentity() throws {
  let valid = try ActivityEventRequest(
    activityID: "agent-2",
    source: "Local Agent",
    title: "Index documents",
    state: .running,
    progress: 1.4
  ).validated()
  #expect(valid.progress == 1)

  #expect(throws: ActivityValidationError.self) {
    try ActivityEventRequest(
      activityID: " ",
      source: "Local Agent",
      title: "Index documents",
      state: .running
    ).validated()
  }
}

@Test
func validationAllowsOnlyApprovedActionURLs() throws {
  for scheme in ["https", "http", "file", "x-apple.systempreferences"] {
    let event = ActivityEventRequest(
      activityID: "agent-url",
      source: "Local Agent",
      title: "Open result",
      state: .succeeded,
      actionURL: URL(string: "\(scheme)://example.com/result")
    )
    #expect(try event.validated().actionURL == event.actionURL)
  }

  for scheme in ["custom-scheme", "javascript", "data"] {
    #expect(throws: ActivityValidationError.self) {
      try ActivityEventRequest(
        activityID: "agent-url",
        source: "Local Agent",
        title: "Open result",
        state: .succeeded,
        actionURL: URL(string: "\(scheme)://example.com/result")
      ).validated()
    }
  }
}

@Test
func eventJSONUsesIntegrationFriendlyKeys() throws {
  let event = ActivityEventRequest(
    activityID: "agent-3",
    source: "Runner",
    title: "Run tests",
    state: .succeeded,
    actionURL: URL(string: "https://example.com/run/3")
  )
  let data = try ActivityCoding.makeEncoder().encode(event)
  let string = String(decoding: data, as: UTF8.self)

  #expect(string.contains("\"activity_id\""))
  #expect(string.contains("\"action_url\""))
  #expect(string.contains("\"succeeded\""))

  let decoded = try ActivityCoding.makeDecoder().decode(
    ActivityEventRequest.self,
    from: data
  )
  #expect(decoded.activityID == event.activityID)
  #expect(decoded.actionURL == event.actionURL)
}

@Test
func identicalUpdatesActAsHeartbeatsWithoutFloodingHistory() {
  let start = Date(timeIntervalSince1970: 1_000)
  var activity = AIActivity(
    event: ActivityEventRequest(
      activityID: "agent-heartbeat",
      source: "Runner",
      title: "Run tests",
      state: .running,
      message: "Testing"
    ),
    now: start
  )

  let heartbeat = start.addingTimeInterval(240)
  let changed = activity.apply(
    ActivityEventRequest(
      activityID: "agent-heartbeat",
      source: "Runner",
      title: "Run tests",
      state: .running,
      message: "Testing"
    ),
    now: heartbeat
  )

  #expect(!changed)
  #expect(activity.lastHeartbeatAt == heartbeat)
  #expect(activity.history.count == 1)
  let expired = activity.expireIfNeeded(
    at: start.addingTimeInterval(500),
    after: 300
  )
  #expect(!expired)
}

@Test
func expiredActivitiesBecomeDisconnectedAndCanReconnect() {
  let start = Date(timeIntervalSince1970: 1_000)
  var activity = AIActivity(
    event: ActivityEventRequest(
      activityID: "agent-stale",
      source: "Runner",
      title: "Run tests",
      state: .running
    ),
    now: start
  )

  let expired = activity.expireIfNeeded(
    at: start.addingTimeInterval(301),
    after: 300
  )
  #expect(expired)
  #expect(activity.state == .stale)
  #expect(activity.state.isTerminal)
  #expect(activity.history.last?.state == .stale)

  activity.apply(
    ActivityEventRequest(
      activityID: "agent-stale",
      source: "Runner",
      title: "Run tests",
      state: .running,
      timestamp: start.addingTimeInterval(10)
    ),
    now: start.addingTimeInterval(302)
  )

  #expect(activity.state == .running)
  #expect(activity.lastHeartbeatAt == start.addingTimeInterval(302))
}

@Test
func decodingLegacyActivityDefaultsHeartbeatToLastUpdate() throws {
  let data = Data(
    """
    {
      "id": "legacy-agent",
      "source": "Runner",
      "title": "Legacy activity",
      "state": "running",
      "started_at": "1970-01-01T00:16:40Z",
      "updated_at": "1970-01-01T00:17:40Z",
      "history": []
    }
    """.utf8
  )

  let activity = try ActivityCoding.makeDecoder().decode(AIActivity.self, from: data)
  #expect(activity.lastHeartbeatAt == Date(timeIntervalSince1970: 1_060))
}

@Test
func clipboardPolicyRejectsSensitivePasteboardTypes() {
  #expect(
    ClipboardCapturePolicy.shouldCapture(
      typeNames: ["public.utf8-plain-text"]
    )
  )
  #expect(
    !ClipboardCapturePolicy.shouldCapture(
      typeNames: [
        "public.utf8-plain-text",
        "org.nspasteboard.ConcealedType",
      ]
    )
  )
  #expect(
    !ClipboardCapturePolicy.shouldCapture(
      typeNames: ["com.agilebits.onepassword"]
    )
  )
}
