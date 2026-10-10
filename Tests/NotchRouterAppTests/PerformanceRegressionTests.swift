import Foundation
import NotchRouterCore
import Testing
@testable import NotchRouterApp

@MainActor
@Test
func unchangedExpiryScanDoesNotPublishActivityUpdates() async throws {
  let identifier = UUID().uuidString
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
  let defaults = try #require(UserDefaults(suiteName: identifier))
  defer {
    defaults.removePersistentDomain(forName: identifier)
    try? FileManager.default.removeItem(at: directory)
  }
  let now = Date(timeIntervalSince1970: 1_000)
  let store = ActivityStore(
    storageURL: directory.appendingPathComponent("activities.json"),
    expiryWindow: 60,
    dateProvider: { now },
    defaults: defaults
  )
  for index in 0..<30 {
    try store.ingest(ActivityEventRequest(
      activityID: "activity-\(index)", source: "Test", title: "Working", state: .running
    ))
  }
  let changes = ObservationChangeCounter { _ = store.activities }

  #expect(!store.expireStaleActivities(at: now.addingTimeInterval(30)))
  #expect(changes.count == 0)
  #expect(store.expireStaleActivities(at: now.addingTimeInterval(61)))
  #expect(store.activities.allSatisfy { $0.state == .stale })
  #expect(changes.count > 0)
  let afterExpiry = changes.count
  #expect(!store.expireStaleActivities(at: now.addingTimeInterval(120)))
  #expect(changes.count == afterExpiry)
  await store.flushPersistence()
}

@MainActor
private final class PendingArtworkLoader {
  var requests: [ArtworkSource] = []
  var continuations: [CheckedContinuation<MusicArtworkPalette?, Never>] = []

  func load(_ url: ArtworkSource) async -> MusicArtworkPalette? {
    requests.append(url)
    return await withCheckedContinuation { continuations.append($0) }
  }

  func finish() {
    for continuation in continuations { continuation.resume(returning: nil) }
    continuations.removeAll()
  }
}

@MainActor
@Test
func mediaHeartbeatsKeepPendingArtworkDownload() async throws {
  let identifier = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: identifier))
  defer { defaults.removePersistentDomain(forName: identifier) }
  let loader = PendingArtworkLoader()
  defer { loader.finish() }
  let controller = MusicController(defaults: defaults, artworkPaletteLoader: { url in
    await loader.load(url)
  })
  let data = Data([1, 2, 3])
  let url = ArtworkSource.browser(data)
  let event = BrowserMediaEvent(
    kind: .update, sessionID: "test", browserName: "Test", title: "Track",
    artworkData: data, isPlaying: true
  )
  _ = try controller.ingestBrowserMedia(event)
  // Let the request begin, but hold its response until after the heartbeats.
  for _ in 0..<100 { await Task.yield() }
  #expect(loader.requests == [url])
  for _ in 0..<5 {
    _ = try controller.ingestBrowserMedia(event)
    for _ in 0..<20 { await Task.yield() }
  }
  #expect(loader.requests == [url])

  let nextData = Data([4, 5, 6])
  let nextURL = ArtworkSource.browser(nextData)
  _ = try controller.ingestBrowserMedia(BrowserMediaEvent(
    kind: .update, sessionID: "test", browserName: "Test", title: "Next track",
    artworkData: nextData, isPlaying: true
  ))
  for _ in 0..<100 { await Task.yield() }
  #expect(loader.requests == [url, nextURL])
  _ = try controller.ingestBrowserMedia(BrowserMediaEvent(
    kind: .ended, sessionID: "test", browserName: "Test"
  ))
  #expect(controller.artworkPalette == nil)
}
