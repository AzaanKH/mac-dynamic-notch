import NotchRouterCore
import Testing

@testable import NotchRouterApp

@MainActor
@Test
func browserDownloadStoreTracksProgressAndReturnsQueuedCommands() throws {
  let store = BrowserDownloadStore()
  let update = BrowserDownloadEvent(
    kind: .update,
    downloadID: 12,
    browserName: "Google Chrome",
    filename: "/Users/test/Downloads/file.zip",
    sourceURL: "https://example.com/file.zip",
    bytesReceived: 250,
    totalBytes: 1_000,
    state: .inProgress,
    isPaused: false,
    canResume: true
  )

  #expect(try store.ingest(update).command == nil)
  let item = try #require(store.activeDownload)
  #expect(item.displayName == "file.zip")
  #expect(item.sourceHost == "example.com")
  #expect(item.progress == 0.25)

  store.pause(item)
  let unrelated = try store.ingest(
    BrowserDownloadEvent(
      kind: .heartbeat,
      browserName: "Microsoft Edge"
    )
  )
  #expect(unrelated.command == nil)

  let response = try store.ingest(
    BrowserDownloadEvent(
      kind: .heartbeat,
      browserName: "Google Chrome"
    )
  )
  #expect(response.command == BrowserDownloadCommand(downloadID: 12, action: .pause))
  #expect(
    try store.ingest(
      BrowserDownloadEvent(
        kind: .heartbeat,
        browserName: "Google Chrome"
      )
    ).command == nil
  )
}

@MainActor
@Test
func browserDownloadStoreKeepsActiveItemsWhenClearingHistory() throws {
  let store = BrowserDownloadStore()
  _ = try store.ingest(
    BrowserDownloadEvent(
      kind: .update,
      downloadID: 1,
      browserName: "Chrome",
      filename: "active.dmg",
      bytesReceived: 1,
      totalBytes: 10,
      state: .inProgress
    )
  )
  _ = try store.ingest(
    BrowserDownloadEvent(
      kind: .update,
      downloadID: 2,
      browserName: "Chrome",
      filename: "finished.dmg",
      bytesReceived: 10,
      totalBytes: 10,
      state: .complete
    )
  )

  store.clearHistory()

  #expect(store.items.count == 1)
  #expect(store.items[0].downloadID == 1)
  #expect(store.activeCount == 1)

  _ = try store.ingest(
    BrowserDownloadEvent(
      kind: .removed,
      downloadID: 1,
      browserName: "Chrome"
    )
  )
  #expect(store.items.isEmpty)
}

@MainActor
@Test
func browserDownloadStoreExpiresAStaleActiveBridge() async throws {
  let store = BrowserDownloadStore(heartbeatTimeout: .milliseconds(20))
  _ = try store.ingest(
    BrowserDownloadEvent(
      kind: .update,
      downloadID: 9,
      browserName: "Chrome",
      filename: "stale.zip",
      state: .inProgress
    )
  )
  #expect(store.activeCount == 1)

  let deadline = ContinuousClock.now + .seconds(1)
  while store.activeCount > 0, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }

  #expect(store.activeCount == 0)
  #expect(store.items[0].state == .interrupted)
  #expect(store.items[0].error == "Browser bridge disconnected.")
}

@MainActor
@Test
func browserDownloadStoreStopsActivePresentationWhenPermissionTurnsOff() throws {
  let store = BrowserDownloadStore()
  _ = try store.ingest(
    BrowserDownloadEvent(
      kind: .update,
      downloadID: 3,
      browserName: "Chrome",
      filename: "active.zip",
      state: .inProgress
    )
  )

  _ = try store.ingest(
    BrowserDownloadEvent(kind: .disabled, browserName: "Chrome")
  )

  #expect(store.activeCount == 0)
  #expect(store.items[0].state == .interrupted)
  #expect(store.items[0].error == "Browser download access is off.")
}

@Test
func chargingEstimateFormatsCalculatingMinutesAndHours() {
  #expect(
    BatteryChargingSnapshot(level: 40, estimate: .calculating).estimateLabel
      == "Calculating…"
  )
  #expect(
    BatteryChargingSnapshot(level: 80, estimate: .minutes(42)).estimateLabel
      == "42m until full"
  )
  #expect(
    BatteryChargingSnapshot(level: 50, estimate: .minutes(125)).estimateLabel
      == "2h 5m until full"
  )
}
