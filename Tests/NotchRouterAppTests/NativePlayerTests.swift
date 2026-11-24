import AppKit
import Foundation
import Testing

@testable import NotchRouterApp

extension NativePlayerClient {
  /// A player that never scripts the real Music or Spotify app and never
  /// registers system-wide observers.
  static func fake(
    running: [MusicSource] = [.appleMusic],
    query: @escaping @Sendable ([MusicSource], TimeInterval) async -> MusicQueryBatch = { _, _ in
      MusicQueryBatch(snapshots: [], errorMessage: nil)
    },
    control: @escaping @Sendable (MusicControl, MusicSource) async -> String? = { _, _ in nil },
    artwork: @escaping @Sendable (String) async -> NativeArtworkResult = { _ in .unavailable }
  ) -> NativePlayerClient {
    NativePlayerClient(
      runningSources: { running },
      query: query,
      control: control,
      artwork: artwork,
      observesSystemNotifications: false
    )
  }
}

private actor PlayerLog {
  private(set) var queries = 0
  private(set) var controls: [MusicControl] = []
  private var gate: CheckedContinuation<Void, Never>?
  private var holdsQueries = false

  func query() async {
    queries += 1
    if holdsQueries { await withCheckedContinuation { gate = $0 } }
  }

  func hold() { holdsQueries = true }

  func release() {
    holdsQueries = false
    gate?.resume()
    gate = nil
  }

  func control(_ control: MusicControl) { controls.append(control) }
}

private let separator = String(UnicodeScalar(31))

private func appleMusicSnapshot(
  shuffle: String = "false", repeatMode: String = "all", favorite: String = "false"
) -> NowPlayingSnapshot? {
  MusicScriptRunner.parse(
    ["playing", "Song", "Artist", "Album", "200", "10", "", "ABC123", shuffle, repeatMode, favorite]
      .joined(separator: separator),
    source: .appleMusic
  )
}

@MainActor
private func enabledController(
  _ suite: String, nativePlayer: NativePlayerClient
) throws -> (MusicController, UserDefaults) {
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.set(true, forKey: MusicController.preferenceKey)
  return (MusicController(defaults: defaults, nativePlayer: nativePlayer), defaults)
}

@MainActor
@Test
func playerNotificationQueriesImmediatelyAndQueuesBehindARunningQuery() async throws {
  let log = PlayerLog()
  let snapshot = try #require(appleMusicSnapshot())
  let suite = "NativePlayer-\(UUID().uuidString)"
  let (controller, defaults) = try enabledController(
    suite,
    nativePlayer: .fake(query: { _, _ in
      await log.query()
      return MusicQueryBatch(snapshots: [snapshot], errorMessage: nil)
    })
  )
  defer { defaults.removePersistentDomain(forName: suite) }

  #expect(await waitUntil { await log.queries == 1 && !controller.isRefreshing })
  #expect(!controller.receivesPlayerNotifications)

  // A notification starts a query right away instead of waiting for the poll.
  let change = Notification(name: MusicController.playerChangeNotifications[.appleMusic]!)
  await log.hold()
  controller.playerStateDidChange(change)
  #expect(await waitUntil { await log.queries == 2 })
  #expect(controller.receivesPlayerNotifications, "Polling can now relax to the backup interval")

  // A change during that query is not dropped: one follow-up runs after it.
  controller.playerStateDidChange(change)
  controller.playerStateDidChange(change)
  await log.release()
  #expect(await waitUntil { await log.queries == 3 && !controller.isRefreshing })
  try await Task.sleep(for: .milliseconds(50))
  #expect(await log.queries == 3)

  // Disabled controls ignore notifications.
  controller.setEnabled(false)
  controller.playerStateDidChange(change)
  #expect(!controller.isRefreshing)
  #expect(!controller.receivesPlayerNotifications)
}

@Test
func appleMusicQueryReadsShuffleRepeatAndFavorite() throws {
  let snapshot = try #require(appleMusicSnapshot(shuffle: "true", repeatMode: "one", favorite: "true"))
  #expect(snapshot.shuffleEnabled == true)
  #expect(snapshot.repeatMode == .one)
  #expect(snapshot.isFavorite == true)

  // Fields the player could not report hide their control.
  let unknown = try #require(appleMusicSnapshot(shuffle: "", repeatMode: "sometimes", favorite: ""))
  #expect(unknown.shuffleEnabled == nil)
  #expect(unknown.repeatMode == nil)
  #expect(unknown.isFavorite == nil)

  let spotify = try #require(
    MusicScriptRunner.parse(
      ["playing", "Song", "Artist", "Album", "200", "10", "https://i.scdn.co/x", ""]
        .joined(separator: separator),
      source: .spotify
    )
  )
  #expect(spotify.shuffleEnabled == nil && spotify.repeatMode == nil && spotify.isFavorite == nil)
}

@Test
func playerOptionCommandsUseMusicScriptingTerms() {
  #expect(
    MusicScriptRunner.controlScript(.setShuffle(true), source: .appleMusic)
      == "tell application id \"com.apple.Music\" to set shuffle enabled to true"
  )
  #expect(
    MusicScriptRunner.controlScript(.setRepeat(.one), source: .appleMusic)
      == "tell application id \"com.apple.Music\" to set song repeat to one"
  )
  // The raw code works whether this Music version calls it favorited or loved.
  #expect(
    MusicScriptRunner.controlScript(.setFavorite(false), source: .appleMusic)
      == "tell application id \"com.apple.Music\" to set «class pLov» of current track to false"
  )
  #expect(MusicRepeatMode.off.next == .all)
  #expect(MusicRepeatMode.all.next == .one)
  #expect(MusicRepeatMode.one.next == .off)
}

@MainActor
@Test
func playerOptionsSendTargetStatesOnlyForAppleMusic() async throws {
  let log = PlayerLog()
  let snapshot = try #require(appleMusicSnapshot(shuffle: "false", repeatMode: "all", favorite: "false"))
  let suite = "NativePlayerOptions-\(UUID().uuidString)"
  let (controller, defaults) = try enabledController(
    suite,
    nativePlayer: .fake(
      query: { _, _ in MusicQueryBatch(snapshots: [snapshot], errorMessage: nil) },
      control: { control, _ in
        await log.control(control)
        return nil
      }
    )
  )
  defer { defaults.removePersistentDomain(forName: suite) }
  #expect(await waitUntil { controller.nowPlaying != nil && !controller.isRefreshing })

  controller.toggleShuffle()
  controller.cycleRepeat()
  controller.toggleFavorite()
  #expect(await waitUntil { await log.controls.count == 3 })
  #expect(await log.controls == [.setShuffle(true), .setRepeat(.one), .setFavorite(true)])

  // Players that do not report the state get no command.
  let spotify = NowPlayingSnapshot(
    source: .spotify, title: "Song", artist: "Artist", album: "Album", isPlaying: true,
    duration: 200, position: 10, artworkURL: nil, sourceName: "Spotify", sourceURL: nil,
    browserSessionID: nil, supportsPrevious: true, supportsNext: true
  )
  controller.apply(MusicQueryBatch(snapshots: [spotify], errorMessage: nil))
  controller.toggleShuffle()
  controller.cycleRepeat()
  controller.toggleFavorite()
  try await Task.sleep(for: .milliseconds(50))
  #expect(await log.controls.count == 3)
}

@Test
func scriptTimeoutStopsTheProcessWithoutWaitingForIt() async {
  let started = Date()
  let result = await MusicScriptRunner.run(script: "delay 10", timeout: 0.3)
  #expect(result.timedOut)
  #expect(result.exitStatus == -1)
  #expect(Date().timeIntervalSince(started) < 3)
}

@Test
func asyncLatchReleasesWaitersOnOpenAndOnDeadline() async {
  let latch = AsyncLatch()
  #expect(await latch.wait(timeout: 0.05) == false)
  async let waiter = latch.wait(timeout: 5)
  try? await Task.sleep(for: .milliseconds(20))
  latch.open()
  #expect(await waiter == true)
  #expect(await latch.wait(timeout: 0) == true, "An open latch releases later waiters at once")
}
