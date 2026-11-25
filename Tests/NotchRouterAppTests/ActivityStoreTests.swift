import Foundation
import NotchRouterCore
import Testing
@testable import NotchRouterApp

@MainActor
@Test
func approvalActivitiesOutrankNewerOrdinaryWork() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  var now = Date(timeIntervalSince1970: 1_000)
  let store = ActivityStore(
    storageURL: directory.appendingPathComponent("activities.json"),
    dateProvider: { now }
  )

  try store.ingest(
    ActivityEventRequest(
      activityID: "approval",
      source: "Codex",
      title: "Review a command",
      state: .needsApproval
    )
  )
  now = now.addingTimeInterval(30)
  try store.ingest(
    ActivityEventRequest(
      activityID: "running",
      source: "Codex",
      title: "Run tests",
      state: .running
    )
  )

  #expect(store.activities.map(\.id) == ["approval", "running"])
  #expect(store.activeActivity?.id == "approval")
  #expect(store.currentActivity?.id == "approval")
  await store.flushPersistence()
}

@MainActor
@Test
func activityGroupsCountsAndSearchesAcrossVisibleFields() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  var now = Date(timeIntervalSince1970: 1_000)
  let store = ActivityStore(
    storageURL: directory.appendingPathComponent("activities.json"),
    dateProvider: { now }
  )

  let events = [
    ActivityEventRequest(
      activityID: "checkout-tests",
      source: "Codex",
      title: "Run checkout tests",
      state: .running,
      message: "Exercising the payment suite"
    ),
    ActivityEventRequest(
      activityID: "release-review",
      source: "DeployBot",
      title: "Review the release",
      state: .needsApproval,
      message: "Production approval required"
    ),
    ActivityEventRequest(
      activityID: "lint-failure",
      source: "CI",
      title: "Lint application",
      state: .failed,
      message: "Two warnings became errors"
    ),
    ActivityEventRequest(
      activityID: "docs-complete",
      source: "Writer",
      title: "Publish documentation",
      state: .succeeded
    ),
  ]

  for event in events {
    now.addTimeInterval(1)
    try store.ingest(event)
  }

  #expect(store.activeCount == 1)
  #expect(store.count(in: .active) == 1)
  #expect(store.count(in: .attentionRequired) == 1)
  #expect(store.count(in: .completed) == 2)
  #expect(
    store.activities(in: .active, matching: "codex payment")
      .map(\.id) == ["checkout-tests"]
  )
  #expect(
    store.activities(in: .attentionRequired, matching: "deploy production")
      .map(\.id) == ["release-review"]
  )
  #expect(
    store.activities(in: .attentionRequired, matching: "approval required")
      .map(\.id) == ["release-review"]
  )
  #expect(
    store.activities(in: .completed, matching: "docs-complete")
      .map(\.id) == ["docs-complete"]
  )
  await store.flushPersistence()
}

@Test
func everyActivityStateBelongsToOnePresentationGroup() {
  #expect(ActivityState.queued.activityGroup == .active)
  #expect(ActivityState.running.activityGroup == .active)
  #expect(ActivityState.needsApproval.activityGroup == .attentionRequired)
  #expect(ActivityState.limited.activityGroup == .attentionRequired)
  #expect(ActivityState.stale.activityGroup == .completed)
  #expect(ActivityState.failed.activityGroup == .completed)
  #expect(ActivityState.succeeded.activityGroup == .completed)
  #expect(ActivityState.cancelled.activityGroup == .completed)
}

@MainActor
@Test
func limitedWorkWaitsForItsResetWithoutHidingWorkInProgress() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  var now = Date(timeIntervalSince1970: 1_000)
  let store = ActivityStore(
    storageURL: directory.appendingPathComponent("activities.json"),
    expiryWindow: 300,
    dateProvider: { now }
  )
  try store.ingest(
    ActivityEventRequest(activityID: "working", source: "Codex", title: "Run tests", state: .running)
  )
  now = now.addingTimeInterval(30)
  try store.ingest(
    ActivityEventRequest(
      activityID: "limited", source: "Claude Code · T3 Code", title: "Draft board", state: .limited,
      message: "You've hit your 5-hour limit · resets 6:30pm (America/Los_Angeles)"
    )
  )

  // Newer, but the closed notch keeps showing the work that is running, and
  // a paused thread is not counted as in progress.
  #expect(store.activities.map(\.id) == ["working", "limited"])
  #expect(store.activeActivity?.id == "working")
  #expect(store.activeCount == 1)
  #expect(store.count(in: .attentionRequired) == 1)

  // Hours pass with no hook: the running work disconnects, the limited
  // thread keeps waiting for its reset.
  #expect(store.expireStaleActivities(at: now.addingTimeInterval(3 * 60 * 60)))
  #expect(store.activities.first { $0.id == "working" }?.state == .stale)
  #expect(store.activities.first { $0.id == "limited" }?.state == .limited)
  #expect(store.activeActivity?.id == "limited")

  // T3 Code resumes the thread after the reset.
  try store.ingest(
    ActivityEventRequest(activityID: "limited", source: "Claude Code · T3 Code", title: "Draft board", state: .running)
  )
  #expect(store.activities.first?.id == "limited")
  #expect(store.activeCount == 1)
  await store.flushPersistence()
}

@MainActor
@Test
func storeExpiresNonterminalActivitiesAfterHeartbeatWindow() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  var now = Date(timeIntervalSince1970: 1_000)
  let store = ActivityStore(
    storageURL: directory.appendingPathComponent("activities.json"),
    expiryWindow: 60,
    dateProvider: { now }
  )
  var visibleUpdateCount = 0
  store.onIngest = { _ in visibleUpdateCount += 1 }

  let heartbeat = ActivityEventRequest(
    activityID: "working",
    source: "Codex",
    title: "Run tests",
    state: .running,
    message: "Testing"
  )
  try store.ingest(heartbeat)
  now = now.addingTimeInterval(45)
  try store.ingest(heartbeat)

  #expect(visibleUpdateCount == 1)
  #expect(!store.expireStaleActivities(at: now.addingTimeInterval(59)))
  #expect(store.activeActivity?.state == .running)
  #expect(store.expireStaleActivities(at: now.addingTimeInterval(61)))
  #expect(store.activeActivity == nil)
  #expect(store.currentActivity?.state == .stale)
  await store.flushPersistence()
}

@MainActor
@Test
func storeRepairsPrivateStoragePermissions() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let storageURL = directory.appendingPathComponent("activities.json")
  defer { try? FileManager.default.removeItem(at: directory) }

  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o755]
  )
  try Data("[]".utf8).write(to: storageURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o644],
    ofItemAtPath: storageURL.path
  )

  let store = ActivityStore(storageURL: storageURL)

  await store.flushPersistence()
  #expect(try permissions(of: directory) == 0o700)
  await store.flushPersistence()
  #expect(try permissions(of: storageURL) == 0o600)

  try store.ingest(
    ActivityEventRequest(
      activityID: "private-activity",
      source: "Codex",
      title: "Review a sensitive action",
      state: .needsApproval,
      actionURL: URL(string: "https://example.com/private-review")
    )
  )

  await store.flushPersistence()
  #expect(try permissions(of: directory) == 0o700)
  await store.flushPersistence()
  #expect(try permissions(of: storageURL) == 0o600)
  await store.flushPersistence()
}

@MainActor
@Test
func activityRetentionLimitTrimsAndPersistsAfterFlush() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let suiteName = "ActivityRetentionTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suiteName)
  }

  var now = Date(timeIntervalSince1970: 1_000)
  let storageURL = directory.appendingPathComponent("activities.json")
  let store = ActivityStore(
    storageURL: storageURL,
    dateProvider: { now },
    defaults: defaults
  )

  for index in 0..<5 {
    now.addTimeInterval(1)
    try store.ingest(
      ActivityEventRequest(
        activityID: "activity-\(index)",
        source: "Test",
        title: "Activity \(index)",
        state: .succeeded
      )
    )
  }

  store.setRetentionLimit(2)

  #expect(store.retentionLimit == 2)
  #expect(store.activities.map(\.id) == ["activity-4", "activity-3"])

  await store.flushPersistence()
  let reloadedStore = ActivityStore(
    storageURL: storageURL,
    defaults: defaults
  )
  #expect(reloadedStore.retentionLimit == 2)
  #expect(reloadedStore.activities.map(\.id) == ["activity-4", "activity-3"])
  await store.flushPersistence()
  await reloadedStore.flushPersistence()
}

@MainActor
@Test
func activityUpdatesRoundTripWithHistoryAndHeartbeat() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let storageURL = directory.appendingPathComponent("activities.json")
  let suiteName = "ActivityPersistenceTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suiteName)
  }

  var now = Date(timeIntervalSince1970: 10_000)
  let store = ActivityStore(
    storageURL: storageURL,
    dateProvider: { now },
    defaults: defaults
  )
  try store.ingest(
    ActivityEventRequest(
      activityID: "persisted-work",
      source: "Codex",
      title: "Prepare release",
      state: .queued,
      message: "Waiting for a worker",
      progress: 0.1
    )
  )
  now.addTimeInterval(15)
  try store.ingest(
    ActivityEventRequest(
      activityID: "persisted-work",
      source: "Codex",
      title: "Prepare release",
      state: .running,
      message: "Running checks",
      progress: 0.6,
      actionURL: URL(string: "https://example.com/release")
    )
  )

  await store.flushPersistence()
  let reloadedStore = ActivityStore(
    storageURL: storageURL,
    dateProvider: { now },
    defaults: defaults
  )
  let activity = try #require(reloadedStore.activities.first)

  #expect(activity.id == "persisted-work")
  #expect(activity.state == .running)
  #expect(activity.message == "Running checks")
  #expect(activity.progress == 0.6)
  #expect(activity.actionURL == URL(string: "https://example.com/release"))
  #expect(activity.startedAt == Date(timeIntervalSince1970: 10_000))
  #expect(activity.updatedAt == now)
  #expect(activity.lastHeartbeatAt == now)
  #expect(activity.history.map(\.state) == [.queued, .running])
  await store.flushPersistence()
  await reloadedStore.flushPersistence()
}

@MainActor
@Test
func clearingAndDismissingActivitiesPersistAfterFlush() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let storageURL = directory.appendingPathComponent("activities.json")
  let suiteName = "ActivityRemovalPersistenceTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suiteName)
  }

  let now = Date()
  let store = ActivityStore(
    storageURL: storageURL,
    dateProvider: { now },
    defaults: defaults
  )
  for (id, state) in [
    ("running", ActivityState.running),
    ("succeeded", .succeeded),
    ("failed", .failed),
  ] {
    try store.ingest(
      ActivityEventRequest(
        activityID: id,
        source: "Test",
        title: id,
        state: state
      )
    )
  }

  store.clearFinished()
  await store.flushPersistence()
  var reloadedStore = ActivityStore(
    storageURL: storageURL,
    dateProvider: { now },
    defaults: defaults
  )
  #expect(reloadedStore.activities.map(\.id) == ["running"])

  reloadedStore.dismiss("running")
  await store.flushPersistence()
  await reloadedStore.flushPersistence()
  reloadedStore = ActivityStore(
    storageURL: storageURL,
    dateProvider: { now },
    defaults: defaults
  )
  #expect(reloadedStore.activities.isEmpty)
  await store.flushPersistence()
  await reloadedStore.flushPersistence()
}

@MainActor
@Test
func heartbeatsDoNotReorderConcurrentActivities() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  var now = Date(timeIntervalSince1970: 1_000)
  let store = ActivityStore(
    storageURL: directory.appendingPathComponent("activities.json"),
    dateProvider: { now }
  )
  let older = ActivityEventRequest(
    activityID: "older",
    source: "Codex",
    title: "Run tests",
    state: .running
  )
  try store.ingest(older)
  now = now.addingTimeInterval(30)
  try store.ingest(
    ActivityEventRequest(
      activityID: "newer",
      source: "Codex",
      title: "Write docs",
      state: .running
    )
  )

  now = now.addingTimeInterval(30)
  try store.ingest(older)

  #expect(store.activities.map(\.id) == ["newer", "older"])
  #expect(store.activeActivity?.id == "newer")

  // The heartbeat still counts as liveness: without it, the older activity
  // would already be past the five-minute window here.
  #expect(!store.expireStaleActivities(at: now.addingTimeInterval(269)))
  await store.flushPersistence()
}

private func permissions(of url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  let value = try #require(attributes[.posixPermissions] as? NSNumber)
  return value.intValue & 0o777
}
