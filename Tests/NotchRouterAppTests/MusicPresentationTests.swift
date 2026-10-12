import CoreGraphics
import Foundation
import NotchRouterCore
import Testing

@testable import NotchRouterApp

@MainActor
@Test
func passiveTrackChangeDoesNotRequestPeek() {
  let event = MusicController.presentationEvent(
    from: snapshot(title: "First song", isPlaying: true),
    to: snapshot(title: "Next song", isPlaying: true)
  )

  #expect(event == .contentChanged)
  #expect(event?.requestsPeek == false)
}

@MainActor
@Test
func startingPlaybackRequestsPeek() {
  let event = MusicController.presentationEvent(
    from: snapshot(title: "Song", isPlaying: false),
    to: snapshot(title: "Song", isPlaying: true)
  )

  #expect(event == .playbackStarted)
  #expect(event?.requestsPeek == true)
}

@MainActor
@Test
func initialPlayingTrackRequestsPeek() {
  let event = MusicController.presentationEvent(
    from: nil,
    to: snapshot(title: "Song", isPlaying: true)
  )

  #expect(event == .playbackStarted)
}

@MainActor
@Test
func viewModelKeepsMusicEventsCompact() {
  let viewModel = NotchViewModel()

  viewModel.musicChanged(
    event: .contentChanged,
    hasActiveActivity: false
  )
  #expect(viewModel.mode == .compact)

  viewModel.musicChanged(
    event: .playbackStarted,
    hasActiveActivity: false
  )
  #expect(viewModel.mode == .compact)
  viewModel.collapse()
}

@MainActor
@Test
func musicPollingAdaptsToPlaybackState() {
  #expect(
    MusicController.pollInterval(
      for: snapshot(title: "Playing", isPlaying: true)
    ) == 8
  )
  #expect(
    MusicController.pollInterval(
      for: snapshot(title: "Paused", isPlaying: false)
    ) == 30
  )
  #expect(MusicController.pollInterval(for: nil) == 30)
}

@MainActor
@Test
func browserMediaBecomesNowPlayingAndReceivesCommands() throws {
  let defaults = UserDefaults(suiteName: #function)!
  defaults.removePersistentDomain(forName: #function)
  defer { defaults.removePersistentDomain(forName: #function) }
  let controller = MusicController(defaults: defaults)
  let event = browserEvent(isPlaying: false)

  let initialResponse = try controller.ingestBrowserMedia(event)
  #expect(initialResponse.command == nil)
  #expect(controller.nowPlaying?.source == .browser)
  #expect(controller.nowPlaying?.sourceName == "Example Video")

  controller.togglePlayback()
  let commandResponse = try controller.ingestBrowserMedia(event)
  #expect(commandResponse.command == .playPause)
  #expect(commandResponse.sessionID == "chromium:7")

  _ = try controller.ingestBrowserMedia(
    BrowserMediaEvent(
      kind: .ended,
      sessionID: "chromium:7",
      browserName: "Google Chrome"
    )
  )
  #expect(controller.nowPlaying == nil)
}

@MainActor
@Test
func browserTransportCapabilitiesArePreserved() throws {
  let defaults = UserDefaults(suiteName: #function)!
  defaults.removePersistentDomain(forName: #function)
  defer { defaults.removePersistentDomain(forName: #function) }
  let controller = MusicController(defaults: defaults)

  _ = try controller.ingestBrowserMedia(browserEvent(isPlaying: true))

  #expect(controller.nowPlaying?.supportsPrevious == true)
  #expect(controller.nowPlaying?.supportsNext == false)
}

private func snapshot(
  title: String,
  isPlaying: Bool
) -> NowPlayingSnapshot {
  NowPlayingSnapshot(
    source: .appleMusic,
    title: title,
    artist: "Artist",
    album: "Album",
    isPlaying: isPlaying,
    duration: 180,
    position: 12,
    artworkURL: nil,
    sourceName: "Music",
    sourceURL: nil,
    browserSessionID: nil,
    supportsPrevious: true,
    supportsNext: true
  )
}

private func browserEvent(isPlaying: Bool) -> BrowserMediaEvent {
  BrowserMediaEvent(
    kind: .update,
    sessionID: "chromium:7",
    browserName: "Google Chrome",
    title: "A useful video",
    artist: "Creator",
    album: "Series",
    siteName: "Example Video",
    pageURL: URL(string: "https://video.example/watch/7"),
    artworkURL: URL(string: "https://video.example/cover.jpg"),
    isPlaying: isPlaying,
    duration: 240,
    position: 18,
    supportsPrevious: true,
    supportsNext: false
  )
}

@MainActor
@Test
func browserSeekingClampsCoalescesAndRejectsInvalidTargets() throws {
  let name = UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let controller = MusicController(defaults: defaults)
  let event = BrowserMediaEvent(
    kind: .update, sessionID: "frame:1", browserName: "Chrome",
    title: "Episode", isPlaying: false, duration: 120, position: 20,
    supportsSeeking: true
  )
  _ = try controller.ingestBrowserMedia(event)
  controller.seek(to: .nan)
  #expect(try controller.ingestBrowserMedia(event).command == nil)
  controller.seek(to: -20)
  var response = try controller.ingestBrowserMedia(event)
  #expect(response.command == .seek)
  #expect(response.seekPosition == 0)
  controller.seek(to: 30)
  controller.seek(to: 500)
  response = try controller.ingestBrowserMedia(event)
  #expect(response.seekPosition == 120)
  #expect(try controller.ingestBrowserMedia(event).command == nil)
}

@MainActor
@Test
func legacyBrowserCannotSeekAndFrameCommandsStayIsolated() throws {
  let name = UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let controller = MusicController(defaults: defaults)
  let legacy = browserEvent(isPlaying: false)
  _ = try controller.ingestBrowserMedia(legacy)
  controller.seek(to: 60)
  #expect(controller.nowPlaying?.canSeek == false)
  #expect(try controller.ingestBrowserMedia(legacy).command == nil)
  let embedded = BrowserMediaEvent(
    kind: .update, sessionID: "frame:2", browserName: "Chrome",
    title: "Embedded episode", isPlaying: true, duration: 100,
    supportsSeeking: true
  )
  _ = try controller.ingestBrowserMedia(embedded)
  controller.seek(to: 45)
  #expect(try controller.ingestBrowserMedia(legacy).command == nil)
  #expect(try controller.ingestBrowserMedia(embedded).seekPosition == 45)
}

@Test
func playbackTimelineInterpolatesRateAndClampsAtDuration() {
  var value = snapshot(title: "Episode", isPlaying: true)
  value.sampledAt = Date(timeIntervalSince1970: 100)
  value.playbackRate = 2
  #expect(value.elapsed(at: Date(timeIntervalSince1970: 110)) == 32)
  #expect(value.elapsed(at: Date(timeIntervalSince1970: 500)) == 180)
  #expect(value.elapsed(at: Date(timeIntervalSince1970: 90)) == 12)
  let paused = snapshot(title: "Episode", isPlaying: false)
  #expect(paused.elapsed(at: Date().addingTimeInterval(50)) == 12)
}

private actor FlakyPaletteLoader {
  private(set) var requests = 0
  let palette: MusicArtworkPalette

  init(palette: MusicArtworkPalette) { self.palette = palette }

  func load() -> MusicArtworkPalette? {
    requests += 1
    return requests == 1 ? nil : palette
  }
}

@MainActor
@Test
func failedArtworkPaletteIsRetriedAfterBackoff() async throws {
  let identifier = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: identifier))
  defer { defaults.removePersistentDomain(forName: identifier) }
  let context = try #require(CGContext(
    data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ))
  context.setFillColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
  let image = try #require(context.makeImage())
  let palette = try #require(MusicArtworkPalette.extract(from: image))
  let loader = FlakyPaletteLoader(palette: palette)
  var now = Date(timeIntervalSince1970: 1_000)
  let controller = MusicController(
    defaults: defaults,
    artworkPaletteLoader: { _ in await loader.load() },
    dateProvider: { now }
  )
  let data = Data([7, 8, 9])
  let heartbeat = BrowserMediaEvent(
    kind: .update, sessionID: "retry", browserName: "Test", title: "Track",
    artworkData: data, isPlaying: true
  )
  // Waits for the loader to have seen `requests` calls and for the controller
  // to finish handling the result, instead of yielding a fixed number of times.
  func settle(requests: Int) async throws {
    for _ in 0..<200 {
      if await loader.requests == requests, !controller.isLoadingArtworkPalette { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Palette load did not settle at \(requests) requests")
  }

  _ = try controller.ingestBrowserMedia(heartbeat)
  try await settle(requests: 1)
  #expect(controller.artworkPalette == nil)

  // Within the backoff window a heartbeat does not start a load at all; the
  // decision is synchronous, so no waiting is needed to observe it.
  now += 5
  _ = try controller.ingestBrowserMedia(heartbeat)
  #expect(!controller.isLoadingArtworkPalette)
  #expect(await loader.requests == 1)

  // Once it elapses, the next heartbeat retries and the palette appears.
  now += MusicController.PaletteFailure.retryDelay(afterAttempts: 1)
  _ = try controller.ingestBrowserMedia(heartbeat)
  try await settle(requests: 2)
  #expect(controller.artworkPalette == palette)
}

@MainActor
@Test
func backgroundBrowserSessionsOutliveTimerThrottling() throws {
  let identifier = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: identifier))
  defer { defaults.removePersistentDomain(forName: identifier) }
  let start = Date(timeIntervalSince1970: 5_000)

  for (isBackground, survives) in [(true, true), (false, false)] {
    let controller = MusicController(defaults: defaults)
    _ = try controller.ingestBrowserMedia(BrowserMediaEvent(
      kind: .update, sessionID: "tab", browserName: "Chrome", title: "Paused episode",
      isPlaying: false, isBackground: isBackground
    ), now: start)
    // Another session's message prunes expired sessions a minute later, as a
    // throttled hidden tab would still be waiting to send its next heartbeat.
    _ = try controller.ingestBrowserMedia(BrowserMediaEvent(
      kind: .ended, sessionID: "other", browserName: "Chrome"
    ), now: start.addingTimeInterval(60))

    #expect((controller.nowPlaying?.title == "Paused episode") == survives)
  }
}

@MainActor
@Test
func nativeControlsRunInOrderAndOnlyMergeAdjacentSeeksForTheSameApp() async {
  let queue = NativeControlQueue()
  var ran: [String] = []
  var release: CheckedContinuation<Void, Never>?
  let run: NativeControlQueue.Run = { control, source in
    if ran.isEmpty { await withCheckedContinuation { release = $0 } }
    switch control {
    case .seek(let position): ran.append("seek \(Int(position)) \(source.rawValue)")
    default: ran.append("\(control) \(source.rawValue)")
    }
  }

  // The first command blocks while the rest queue behind it.
  queue.enqueue(.next, source: .spotify, run: run)
  guard await waitUntil({ release != nil }) else {
    Issue.record("The first command never started")
    return
  }
  queue.enqueue(.seek(10), source: .spotify, run: run)
  queue.enqueue(.previous, source: .spotify, run: run)
  queue.enqueue(.seek(20), source: .spotify, run: run)
  queue.enqueue(.seek(30), source: .spotify, run: run)  // merges into seek 20
  queue.enqueue(.seek(40), source: .appleMusic, run: run)  // different app: no merge
  release?.resume()
  await queue.drain()

  #expect(ran == [
    "next spotify",
    "seek 10 spotify",
    "previous spotify",
    "seek 30 spotify",
    "seek 40 appleMusic",
  ])
}

@MainActor
@Test
func cancellingNativeControlsDropsQueuedCommands() async {
  let queue = NativeControlQueue()
  var ran: [MusicControl] = []
  var release: CheckedContinuation<Void, Never>?
  let run: NativeControlQueue.Run = { control, _ in
    if ran.isEmpty, release == nil { await withCheckedContinuation { release = $0 } }
    ran.append(control)
  }

  queue.enqueue(.playPause, source: .appleMusic, run: run)
  guard await waitUntil({ release != nil }) else {
    Issue.record("The first command never started")
    return
  }
  queue.enqueue(.next, source: .appleMusic, run: run)
  queue.enqueue(.seek(5), source: .appleMusic, run: run)
  queue.cancelPending()  // the integration was disabled
  release?.resume()
  await queue.drain()

  #expect(ran == [.playPause])
}

@MainActor
private func seekableBrowserSession(
  _ controller: MusicController, position: Double, now: Date
) throws -> BrowserMediaEvent {
  let event = BrowserMediaEvent(
    kind: .update, sessionID: "player", browserName: "Chrome", title: "Episode",
    isPlaying: false, duration: 300, position: position,
    supportsPrevious: true, supportsNext: true, supportsSeeking: true
  )
  _ = try controller.ingestBrowserMedia(event, now: now)
  return event
}

/// Commands the app hands to the extension, one per heartbeat, until empty.
@MainActor
private func deliveredCommands(
  _ controller: MusicController, heartbeat: BrowserMediaEvent, now: Date
) throws -> [String] {
  var delivered: [String] = []
  for _ in 0..<10 {
    let response = try controller.ingestBrowserMedia(heartbeat, now: now)
    guard let command = response.command else { break }
    delivered.append(response.seekPosition.map { "\(command.rawValue) \(Int($0))" } ?? command.rawValue)
  }
  return delivered
}

@MainActor
@Test
func browserSeeksMergeOnlyIntoAnAdjacentSeek() throws {
  let identifier = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: identifier))
  defer { defaults.removePersistentDomain(forName: identifier) }
  let now = Date(timeIntervalSince1970: 9_000)
  let controller = MusicController(defaults: defaults, dateProvider: { now })
  let heartbeat = try seekableBrowserSession(controller, position: 100, now: now)

  controller.seek(to: 30)
  controller.previousTrack()
  controller.seek(to: 60)
  controller.seek(to: 70)  // merges into the seek just before it

  #expect(try deliveredCommands(controller, heartbeat: heartbeat, now: now) == [
    "seek 30", "previous", "seek 70",
  ])
}

@MainActor
@Test
func repeatedSkipsBuildOnThePreviousTargetUntilThePlayerReportsBack() throws {
  let identifier = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: identifier))
  defer { defaults.removePersistentDomain(forName: identifier) }
  let now = Date(timeIntervalSince1970: 9_000)
  let controller = MusicController(defaults: defaults, dateProvider: { now })
  _ = try seekableBrowserSession(controller, position: 1, now: now)
  func heartbeat(at position: Double) -> BrowserMediaEvent {
    BrowserMediaEvent(
      kind: .update, sessionID: "player", browserName: "Chrome", title: "Episode",
      isPlaying: false, duration: 300, position: position,
      supportsPrevious: true, supportsNext: true, supportsSeeking: true
    )
  }

  // Both clicks land before any new snapshot, so the second builds on 16.
  controller.skip(by: 15)
  controller.skip(by: 15)
  #expect(try deliveredCommands(controller, heartbeat: heartbeat(at: 31), now: now) == ["seek 31"])

  // Once the player reports its new position, the next skip starts from it.
  controller.skip(by: 15)
  #expect(try deliveredCommands(controller, heartbeat: heartbeat(at: 46), now: now) == ["seek 46"])
}

@MainActor
@Test
func skipsBuildOnAnInterveningSeekAndResetAfterOtherTransportCommands() throws {
  let identifier = UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: identifier))
  defer { defaults.removePersistentDomain(forName: identifier) }
  let now = Date(timeIntervalSince1970: 9_000)
  let controller = MusicController(defaults: defaults, dateProvider: { now })
  let heartbeat = try seekableBrowserSession(controller, position: 1, now: now)

  // A slider seek between two skips becomes the base for the next skip.
  controller.skip(by: 15)
  controller.seek(to: 100)
  controller.skip(by: 15)
  #expect(try deliveredCommands(controller, heartbeat: heartbeat, now: now) == ["seek 115"])

  // Toggling playback forgets the pending target, so the skip starts from
  // the last reported position again.
  let toggled = MusicController(defaults: defaults, dateProvider: { now })
  let toggledHeartbeat = try seekableBrowserSession(toggled, position: 1, now: now)
  toggled.skip(by: 15)
  toggled.togglePlayback()
  toggled.skip(by: 15)
  #expect(try deliveredCommands(toggled, heartbeat: toggledHeartbeat, now: now) == [
    "seek 16", "play_pause", "seek 16",
  ])
}
