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
    displayName: "file.zip",
    sourceHost: "example.com",
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
      displayName: "active.dmg",
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
      displayName: "finished.dmg",
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
func browserDownloadStoreExpiresAStaleActiveBridge() throws {
  let store = BrowserDownloadStore()
  _ = try store.ingest(
    BrowserDownloadEvent(
      kind: .update,
      downloadID: 9,
      browserName: "Chrome",
      displayName: "stale.zip",
      state: .inProgress
    )
  )
  #expect(store.activeCount == 1)

  store.expireActiveDownloads(from: "Chrome")

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
      displayName: "active.zip",
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
