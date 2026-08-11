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
func viewModelOnlyPeeksForRequestedMusicEvents() {
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
  #expect(viewModel.mode == .peek)
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
func trackChangesUseFastFollowUpPolls() {
  #expect(
    MusicController.transportRefreshDelays == [
      .milliseconds(120),
      .milliseconds(480),
    ]
  )
}

@MainActor
@Test
func browserMediaBecomesNowPlayingAndReceivesCommands() throws {
  let defaults = UserDefaults(suiteName: #function)!
  defaults.removePersistentDomain(forName: #function)
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
