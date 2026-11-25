import AppKit
import Observation
import Foundation
import NotchRouterCore

enum MusicSource: String, Codable, CaseIterable, Sendable {
  case appleMusic
  case spotify
  case browser

  static let nativeCases: [MusicSource] = [.appleMusic, .spotify]

  var displayName: String {
    switch self {
    case .appleMusic: "Music"
    case .spotify: "Spotify"
    case .browser: "Browser"
    }
  }

  var bundleIdentifier: String {
    switch self {
    case .appleMusic: "com.apple.Music"
    case .spotify: "com.spotify.client"
    case .browser: ""
    }
  }

  var symbolName: String {
    switch self {
    case .appleMusic: "music.note"
    case .spotify: "waveform"
    case .browser: "globe"
    }
  }
}

struct NowPlayingSnapshot: Equatable, Sendable {
  let source: MusicSource
  let title: String
  let artist: String
  let album: String
  let isPlaying: Bool
  let duration: Double
  let position: Double
  let artworkURL: URL?
  let sourceName: String
  let sourceURL: URL?
  let browserSessionID: String?
  let supportsPrevious: Bool
  let supportsNext: Bool
  var supportsSeeking: Bool = true
  var playbackRate: Double = 1
  var sampledAt: Date = Date()
  var artworkData: Data?
  /// Apple Music's persistent ID for the track, used to match its cover.
  var trackID: String?
  /// Apple Music only; `nil` hides the control.
  var shuffleEnabled: Bool?
  var repeatMode: MusicRepeatMode?
  var isFavorite: Bool?

  var artworkSource: ArtworkSource? {
    switch source {
    case .browser: artworkData.map(ArtworkSource.browser)
    case .appleMusic: artworkData.map(ArtworkSource.appleMusic)
    case .spotify: artworkURL.map(ArtworkSource.spotify)
    }
  }

  var canSeek: Bool {
    supportsSeeking && duration.isFinite && duration > 0
  }

  var identity: String {
    "\(browserSessionID ?? source.rawValue)|\(title)|\(artist)|\(album)"
  }

  func elapsed(at date: Date) -> Double {
    let base = position.isFinite ? max(0, position) : 0
    let delta = isPlaying ? max(0, date.timeIntervalSince(sampledAt)) * playbackRate : 0
    let value = base + (delta.isFinite ? delta : 0)
    return duration.isFinite && duration > 0 ? min(duration, value) : value
  }
}

enum MusicPresentationEvent: Equatable, Sendable {
  case contentChanged
  case playbackStarted
  case userTransport

  var requestsPeek: Bool {
    switch self {
    case .playbackStarted, .userTransport:
      true
    case .contentChanged:
      false
    }
  }
}

@MainActor
@Observable
final class MusicController: NSObject {
  static let preferenceKey = "musicIntegrationEnabled"
  static let playingPollInterval: TimeInterval = 8
  static let inactivePollInterval: TimeInterval = 30
  /// Once a player has posted a change notification, polling is only a
  /// backup for missed notifications and for seeks made inside the player.
  static let notifiedPlayingPollInterval: TimeInterval = 20
  static let notifiedInactivePollInterval: TimeInterval = 60
  /// Posted by Music and Spotify whenever the track or playback state changes.
  static let playerChangeNotifications: [MusicSource: Notification.Name] = [
    .appleMusic: Notification.Name("com.apple.Music.playerInfo"),
    .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged"),
  ]
  private static let transportRefreshDelays: [Duration] = [
    .milliseconds(120),
    .milliseconds(480),
  ]
  static let browserSessionTimeout: TimeInterval = 12
  /// Hidden, silent tabs can have timers throttled to once a minute. Closed
  /// tabs and unloaded pages still end their sessions explicitly.
  static let backgroundBrowserSessionTimeout: TimeInterval = 90
  static let artworkPaletteCacheLimit = 12
  /// Failed Apple Music cover reads are retried on later polls up to this many times.
  static let appleMusicArtworkAttempts = 3

  private(set) var isEnabled: Bool
  private(set) var nowPlaying: NowPlayingSnapshot?
  private(set) var permissionMessage: String?
  private(set) var artworkPalette: MusicArtworkPalette?

  let systemVolume = SystemVolumeController()

  var onChange: ((MusicPresentationEvent) -> Void)?

  private var timer: Timer?
  private var browserExpiryTimer: Timer?
  private var refreshTask: Task<Void, Never>?
  private var transportRefreshTask: Task<Void, Never>?
  @ObservationIgnored private let nativeControls = NativeControlQueue()
  @ObservationIgnored private var pendingPosition: PendingPosition?

  /// The last seek target sent before the player reported a new snapshot.
  private struct PendingPosition {
    let identity: String
    let sampledAt: Date
    let target: Double
    let issuedAt: Date
  }
  private var refreshAfterCurrentTask = false
  private var nativeSnapshots: [NowPlayingSnapshot] = []
  /// The cover for one Apple Music track. It is read once per track, not on
  /// every poll, because the bytes can be large.
  private struct AppleMusicArtwork {
    let trackID: String
    var data: Data?
    var isSettled = false
    var failures = 0
  }
  @ObservationIgnored private var appleMusicArtwork: AppleMusicArtwork?
  @ObservationIgnored private var appleMusicArtworkTask: Task<Void, Never>?
  /// Whether an Apple Music cover read is running. Lets tests wait for it.
  var isLoadingAppleMusicArtwork: Bool { appleMusicArtworkTask != nil }
  /// Whether a native player query is running. Lets tests wait for it.
  var isRefreshing: Bool { refreshTask != nil }
  private let nativePlayer: NativePlayerClient
  @ObservationIgnored private var isObservingPlayers = false
  /// Set by the first change notification. Until then polling stays fast,
  /// in case a player version does not post notifications.
  @ObservationIgnored private(set) var receivesPlayerNotifications = false
  private var browserSessions: [String: BrowserSession] = [:]
  private var pendingBrowserCommands: [String: [PendingBrowserControl]] = [:]
  private var artworkPaletteCache: [ArtworkSource: MusicArtworkPalette] = [:]
  /// Failed covers are retried with bounded backoff. The loader cannot tell a
  /// network timeout from an undecodable image, so neither is permanent.
  private var artworkPaletteFailures: [ArtworkSource: PaletteFailure] = [:]
  private var artworkPaletteTask: Task<Void, Never>?
  private var artworkPaletteRequestURL: ArtworkSource?
  /// Whether a palette load is running. Lets tests wait for it to settle.
  var isLoadingArtworkPalette: Bool { artworkPaletteTask != nil }
  private let artworkPaletteLoader: @Sendable (ArtworkSource) async -> MusicArtworkPalette?
  private let defaults: UserDefaults
  private let dateProvider: () -> Date

  struct PaletteFailure {
    var attempts: Int
    var retryAt: Date

    static func retryDelay(afterAttempts attempts: Int) -> TimeInterval {
      ArtworkLoader.retryDelay(afterAttempts: attempts)
    }
  }

  init(
    defaults: UserDefaults = .standard,
    artworkPaletteLoader: @escaping @Sendable (ArtworkSource) async -> MusicArtworkPalette? = {
      await MusicArtworkPalette.load(source: $0)
    },
    nativePlayer: NativePlayerClient = .live,
    dateProvider: @escaping () -> Date = Date.init
  ) {
    self.artworkPaletteLoader = artworkPaletteLoader
    self.nativePlayer = nativePlayer
    self.dateProvider = dateProvider
    self.defaults = defaults
    isEnabled = defaults.bool(forKey: Self.preferenceKey)
    super.init()
    if isEnabled {
      startObservingPlayers()
      refresh()
    }
  }

  /// Distributed notifications are held back while an app is inactive unless
  /// they are observed with `.deliverImmediately`. NotchRouter is almost never
  /// the active app, so the block-based API would delay them until a click.
  private func startObservingPlayers() {
    guard nativePlayer.observesSystemNotifications, !isObservingPlayers else { return }
    isObservingPlayers = true
    let center = DistributedNotificationCenter.default()
    for name in Self.playerChangeNotifications.values {
      center.addObserver(
        self,
        selector: #selector(playerStateDidChange(_:)),
        name: name,
        object: nil,
        suspensionBehavior: .deliverImmediately
      )
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(applicationDidTerminate(_:)),
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil
    )
  }

  private func stopObservingPlayers() {
    guard isObservingPlayers else { return }
    isObservingPlayers = false
    DistributedNotificationCenter.default().removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  /// A player changed track or state. The notification only triggers a
  /// query; the query stays the single source of truth for what is shown.
  @objc func playerStateDidChange(_ notification: Notification) {
    guard isEnabled else { return }
    receivesPlayerNotifications = true
    refresh(priority: true)
  }

  @objc private func applicationDidTerminate(_ notification: Notification) {
    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    guard isEnabled,
      MusicSource.nativeCases.contains(where: { $0.bundleIdentifier == app?.bundleIdentifier })
    else { return }
    refresh(priority: true)
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.preferenceKey)
    permissionMessage = nil

    if enabled {
      startObservingPlayers()
      refresh(allowsPermissionPrompt: true)
    } else {
      stopObservingPlayers()
      receivesPlayerNotifications = false
      nativeControls.cancelPending()
      stopPolling()
      refreshTask?.cancel()
      refreshTask = nil
      transportRefreshTask?.cancel()
      transportRefreshTask = nil
      refreshAfterCurrentTask = false
      appleMusicArtworkTask?.cancel()
      appleMusicArtworkTask = nil
      appleMusicArtwork = nil
      nativeSnapshots = []
      selectNowPlaying()
    }
  }

  func refresh(
    allowsPermissionPrompt: Bool = false,
    priority: Bool = false
  ) {
    guard isEnabled else { return }
    guard refreshTask == nil else {
      if priority {
        refreshAfterCurrentTask = true
      }
      return
    }

    let runningSources = nativePlayer.runningSources()
    guard !runningSources.isEmpty else {
      apply(MusicQueryBatch(snapshots: [], errorMessage: nil))
      return
    }

    let query = nativePlayer.query
    refreshTask = Task { [weak self] in
      let timeout = allowsPermissionPrompt ? 15.0 : 2.0
      let batch = await query(runningSources, timeout)
      guard let self, !Task.isCancelled else { return }
      self.refreshTask = nil
      self.apply(batch)
      if self.refreshAfterCurrentTask {
        self.refreshAfterCurrentTask = false
        self.refresh()
      }
    }
  }

  func togglePlayback() {
    pendingPosition = nil
    executeControl(.playPause)
  }

  func nextTrack() {
    pendingPosition = nil
    executeControl(.next)
  }

  func previousTrack() {
    pendingPosition = nil
    executeControl(.previous)
  }

  /// Shuffle, repeat, and favorite are Apple Music only. Each sends the
  /// target state rather than a toggle, so a repeated click cannot undo a
  /// command that has not been reflected by a query yet.
  func toggleShuffle() {
    guard let snapshot = nowPlaying, snapshot.source == .appleMusic,
      let enabled = snapshot.shuffleEnabled
    else { return }
    executeControl(.setShuffle(!enabled))
  }

  func cycleRepeat() {
    guard let snapshot = nowPlaying, snapshot.source == .appleMusic,
      let mode = snapshot.repeatMode
    else { return }
    executeControl(.setRepeat(mode.next))
  }

  func toggleFavorite() {
    guard let snapshot = nowPlaying, snapshot.source == .appleMusic,
      let favorite = snapshot.isFavorite
    else { return }
    executeControl(.setFavorite(!favorite))
  }

  func seek(to position: Double) {
    guard let snapshot = nowPlaying, snapshot.canSeek, position.isFinite else { return }
    let target = min(snapshot.duration, max(0, position))
    pendingPosition = PendingPosition(
      identity: snapshot.identity, sampledAt: snapshot.sampledAt,
      target: target, issuedAt: dateProvider()
    )
    executeControl(.seek(target))
  }

  func skip(by seconds: Double) {
    guard let snapshot = nowPlaying else { return }
    let now = dateProvider()
    var base = snapshot.elapsed(at: now)
    // Skips before the player reports back build on the last seek target
    // rather than the stale snapshot. A new snapshot resets this.
    if let pending = pendingPosition, pending.identity == snapshot.identity,
      pending.sampledAt == snapshot.sampledAt
    {
      let played = snapshot.isPlaying
        ? max(0, now.timeIntervalSince(pending.issuedAt)) * snapshot.playbackRate
        : 0
      base = pending.target + played
    }
    seek(to: base + seconds)
  }

  func openSource(_ source: MusicSource) {
    if source == .browser {
      guard let url = nowPlaying?.sourceURL else { return }
      NSWorkspace.shared.open(url)
      return
    }
    guard
      let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: source.bundleIdentifier
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  func ingestBrowserMedia(
    _ event: BrowserMediaEvent,
    now: Date = Date()
  ) throws -> BrowserMediaBridgeResponse {
    let event = try event.validated()
    let sessionID = event.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      sessionID == event.sessionID,
      !sessionID.isEmpty,
      sessionID.count <= 200
    else {
      throw BrowserMediaValidationError.invalidSession
    }
    pruneBrowserSessions(now: now)

    switch event.kind {
    case .ended:
      browserSessions.removeValue(forKey: event.sessionID)
      pendingBrowserCommands.removeValue(forKey: event.sessionID)
    case .update:
      var snapshot = try Self.browserSnapshot(from: event)
      snapshot.sampledAt = now
      browserSessions[event.sessionID] = BrowserSession(
        snapshot: snapshot,
        lastSeenAt: now,
        timeout: event.isBackground == true
          ? Self.backgroundBrowserSessionTimeout
          : Self.browserSessionTimeout
      )
    }

    selectNowPlaying()
    scheduleBrowserExpiry()
    var commands = pendingBrowserCommands[event.sessionID] ?? []
    let command = commands.isEmpty ? nil : commands.removeFirst()
    if commands.isEmpty {
      pendingBrowserCommands.removeValue(forKey: event.sessionID)
    } else {
      pendingBrowserCommands[event.sessionID] = commands
    }
    return BrowserMediaBridgeResponse(
      status: "ok",
      sessionID: event.sessionID,
      command: command?.command,
      seekPosition: command?.position
    )
  }

  var hasBrowserSession: Bool {
    !browserSessions.isEmpty
  }

  static func pollInterval(
    for snapshot: NowPlayingSnapshot?,
    receivesNotifications: Bool = false
  ) -> TimeInterval {
    switch (snapshot?.isPlaying == true, receivesNotifications) {
    case (true, false): playingPollInterval
    case (false, false): inactivePollInterval
    case (true, true): notifiedPlayingPollInterval
    case (false, true): notifiedInactivePollInterval
    }
  }

  private func scheduleNextPoll() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(
      timeInterval: Self.pollInterval(
        for: nowPlaying,
        receivesNotifications: receivesPlayerNotifications
      ),
      target: self,
      selector: #selector(poll),
      userInfo: nil,
      repeats: false
    )
    timer?.tolerance = nowPlaying?.isPlaying == true ? 1 : 5
  }

  private func stopPolling() {
    timer?.invalidate()
    timer = nil
  }

  @objc private func poll() {
    timer = nil
    refresh()
  }

  @objc private func expireBrowserSessions() {
    browserExpiryTimer = nil
    pruneBrowserSessions(now: Date())
    selectNowPlaying()
    scheduleBrowserExpiry()
  }

  private func scheduleBrowserExpiry() {
    browserExpiryTimer?.invalidate()
    browserExpiryTimer = nil
    guard
      let nextExpiry = browserSessions.values
        .map({ $0.lastSeenAt.addingTimeInterval($0.timeout) })
        .min()
    else { return }

    let timer = Timer(
      fireAt: max(nextExpiry, Date().addingTimeInterval(0.1)),
      interval: 0,
      target: self,
      selector: #selector(expireBrowserSessions),
      userInfo: nil,
      repeats: false
    )
    RunLoop.main.add(timer, forMode: .common)
    browserExpiryTimer = timer
  }

  func apply(_ batch: MusicQueryBatch) {
    nativeSnapshots = batch.snapshots.map(attachingAppleMusicArtwork)
    requestAppleMusicArtworkIfNeeded()
    selectNowPlaying()
    permissionMessage = nowPlaying == nil ? batch.errorMessage : nil
    scheduleNextPoll()
  }

  private func attachingAppleMusicArtwork(
    to snapshot: NowPlayingSnapshot
  ) -> NowPlayingSnapshot {
    guard snapshot.source == .appleMusic,
      let trackID = snapshot.trackID,
      let artwork = appleMusicArtwork, artwork.trackID == trackID
    else { return snapshot }
    var snapshot = snapshot
    snapshot.artworkData = artwork.data
    return snapshot
  }

  private func requestAppleMusicArtworkIfNeeded() {
    guard
      let trackID = nativeSnapshots.first(where: { $0.source == .appleMusic })?.trackID
    else {
      appleMusicArtworkTask?.cancel()
      appleMusicArtworkTask = nil
      appleMusicArtwork = nil
      return
    }
    if let artwork = appleMusicArtwork, artwork.trackID == trackID {
      guard appleMusicArtworkTask == nil, !artwork.isSettled,
        artwork.failures < Self.appleMusicArtworkAttempts
      else { return }
    } else {
      appleMusicArtworkTask?.cancel()
      appleMusicArtworkTask = nil
      appleMusicArtwork = AppleMusicArtwork(trackID: trackID)
    }

    let fetch = nativePlayer.artwork
    appleMusicArtworkTask = Task { [weak self] in
      let result = await fetch(trackID)
      guard let self, !Task.isCancelled,
        var artwork = self.appleMusicArtwork, artwork.trackID == trackID
      else { return }
      self.appleMusicArtworkTask = nil
      switch result {
      case .artwork(let data):
        artwork.data = data
        artwork.isSettled = true
      case .unavailable:
        artwork.isSettled = true
      case .failed:
        artwork.failures += 1
      }
      self.appleMusicArtwork = artwork
      self.nativeSnapshots = self.nativeSnapshots.map(self.attachingAppleMusicArtwork)
      self.selectNowPlaying()
    }
  }

  private func selectNowPlaying() {
    let oldSnapshot = nowPlaying
    let browserSnapshots = browserSessions.values
      .sorted { $0.lastSeenAt > $1.lastSeenAt }
      .map(\.snapshot)
    nowPlaying =
      browserSnapshots.first(where: \.isPlaying)
      ?? nativeSnapshots.first(where: \.isPlaying)
      ?? browserSnapshots.first
      ?? nativeSnapshots.first
    updateArtworkPalette()

    if let event = Self.presentationEvent(
      from: oldSnapshot,
      to: nowPlaying
    ) {
      onChange?(event)
    }
  }

  private func updateArtworkPalette() {
    let url = nowPlaying?.artworkSource
    let now = dateProvider()
    if url == artworkPaletteRequestURL {
      // Heartbeats keep the same request. Only a failed cover whose backoff has
      // elapsed is requested again.
      guard let url, artworkPaletteTask == nil, artworkPalette == nil,
        let failure = artworkPaletteFailures[url], now >= failure.retryAt
      else { return }
    } else {
      artworkPaletteTask?.cancel()
      artworkPaletteTask = nil
      artworkPaletteRequestURL = url
      guard let url else {
        if artworkPalette != nil { artworkPalette = nil }
        return
      }
      if let cached = artworkPaletteCache[url] {
        if artworkPalette != cached { artworkPalette = cached }
        return
      }
      if artworkPalette != nil { artworkPalette = nil }
      if let failure = artworkPaletteFailures[url], now < failure.retryAt { return }
    }
    guard let url else { return }

    let loader = artworkPaletteLoader
    artworkPaletteTask = Task { [weak self] in
      let palette = await loader(url)
      guard let self, !Task.isCancelled else { return }
      self.artworkPaletteTask = nil
      guard self.artworkPaletteRequestURL == url else { return }
      guard let palette else {
        let attempts = (self.artworkPaletteFailures[url]?.attempts ?? 0) + 1
        if self.artworkPaletteFailures[url] == nil,
          self.artworkPaletteFailures.count >= Self.artworkPaletteCacheLimit
        {
          self.artworkPaletteFailures.removeAll(keepingCapacity: true)
        }
        self.artworkPaletteFailures[url] = PaletteFailure(
          attempts: attempts,
          retryAt: self.dateProvider().addingTimeInterval(
            PaletteFailure.retryDelay(afterAttempts: attempts)
          )
        )
        return
      }
      self.artworkPaletteFailures[url] = nil
      if self.artworkPaletteCache.count >= Self.artworkPaletteCacheLimit {
        self.artworkPaletteCache.removeAll(keepingCapacity: true)
      }
      self.artworkPaletteCache[url] = palette
      self.artworkPalette = palette
    }
  }

  static func presentationEvent(
    from oldSnapshot: NowPlayingSnapshot?,
    to newSnapshot: NowPlayingSnapshot?
  ) -> MusicPresentationEvent? {
    guard let oldSnapshot, let newSnapshot else {
      guard oldSnapshot != nil || newSnapshot != nil else { return nil }
      return newSnapshot?.isPlaying == true
        ? .playbackStarted
        : .contentChanged
    }
    if !oldSnapshot.isPlaying, newSnapshot.isPlaying {
      return .playbackStarted
    }
    let contentChanged =
      oldSnapshot.source != newSnapshot.source
      || oldSnapshot.sourceName != newSnapshot.sourceName
      || oldSnapshot.title != newSnapshot.title
      || oldSnapshot.artist != newSnapshot.artist
      || oldSnapshot.album != newSnapshot.album
      || oldSnapshot.isPlaying != newSnapshot.isPlaying
      || oldSnapshot.artworkURL != newSnapshot.artworkURL
      || oldSnapshot.artworkData != newSnapshot.artworkData
      || oldSnapshot.sourceURL != newSnapshot.sourceURL
    return contentChanged ? .contentChanged : nil
  }

  private func executeControl(_ control: MusicControl) {
    if nowPlaying?.source == .browser {
      executeBrowserControl(control)
      return
    }
    guard isEnabled else { return }
    let source =
      nowPlaying?.source
      ?? nativePlayer.runningSources().first
    guard let source else { return }
    let requestsPeek =
      control == .next
      || control == .previous
      || (control == .playPause && nowPlaying?.isPlaying != true)

    let run = nativePlayer.control
    nativeControls.enqueue(control, source: source) { [weak self] control, source in
      // The integration can be disabled while this command waits its turn.
      guard let self, self.isEnabled else { return }
      let error = await run(control, source)
      self.permissionMessage = error
      if error == nil, requestsPeek {
        self.onChange?(.userTransport)
      }
      if error == nil, control == .next || control == .previous {
        self.scheduleTransportRefreshes()
      } else {
        self.refresh(priority: true)
      }
    }
  }

  private func executeBrowserControl(_ control: MusicControl) {
    guard
      let snapshot = nowPlaying,
      let sessionID = snapshot.browserSessionID
    else { return }

    let command: BrowserMediaCommand
    var position: Double?
    switch control {
    case .playPause:
      command = .playPause
    case .previous:
      guard snapshot.supportsPrevious else { return }
      command = .previous
    case .next:
      guard snapshot.supportsNext else { return }
      command = .next
    case .seek(let target):
      guard snapshot.canSeek else { return }
      command = .seek
      position = target
    case .setShuffle, .setRepeat, .setFavorite:
      return
    }
    var commands = pendingBrowserCommands[sessionID] ?? []
    // A seek merges only into a seek queued directly before it, so it never
    // jumps ahead of (or drops a seek placed before) another command.
    if command == .seek, commands.last?.command == .seek {
      commands[commands.count - 1] = PendingBrowserControl(command: .seek, position: position)
    } else if commands.count < 8 {
      commands.append(PendingBrowserControl(command: command, position: position))
    }
    pendingBrowserCommands[sessionID] = commands

    let requestsPeek =
      control == .next
      || control == .previous
      || (control == .playPause && !snapshot.isPlaying)
    if requestsPeek {
      onChange?(.userTransport)
    }
  }

  private func pruneBrowserSessions(now: Date) {
    let expiredIDs = browserSessions.compactMap { id, session in
      now.timeIntervalSince(session.lastSeenAt) > session.timeout
        ? id
        : nil
    }
    for id in expiredIDs {
      browserSessions.removeValue(forKey: id)
      pendingBrowserCommands.removeValue(forKey: id)
    }
  }

  private static func browserSnapshot(
    from event: BrowserMediaEvent
  ) throws -> NowPlayingSnapshot {
    let sessionID = event.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !sessionID.isEmpty, sessionID.count <= 200 else {
      throw BrowserMediaValidationError.invalidSession
    }
    guard !title.isEmpty, title.count <= 500 else {
      throw BrowserMediaValidationError.invalidTitle
    }
    guard event.pageURL.map(isWebURL) ?? true,
      event.artworkURL.map(isWebURL) ?? true
    else {
      throw BrowserMediaValidationError.invalidURL
    }

    let browserName = bounded(event.browserName, limit: 80, fallback: "Browser")
    let siteName = bounded(event.siteName, limit: 120, fallback: browserName)
    return NowPlayingSnapshot(
      source: .browser,
      title: title,
      artist: bounded(event.artist, limit: 300, fallback: siteName),
      album: bounded(event.album, limit: 300, fallback: siteName),
      isPlaying: event.isPlaying ?? false,
      duration: finiteNonnegative(event.duration),
      position: finiteNonnegative(event.position),
      artworkURL: nil,
      sourceName: siteName,
      sourceURL: event.pageURL,
      browserSessionID: sessionID,
      supportsPrevious: event.supportsPrevious ?? false,
      supportsNext: event.supportsNext ?? false,
      supportsSeeking: event.supportsSeeking ?? false,
      playbackRate: event.playbackRate.map { $0.isFinite && $0 >= 0 ? $0 : 1 } ?? 1,
      artworkData: event.artworkData
    )
  }

  private static func bounded(
    _ value: String?,
    limit: Int,
    fallback: String
  ) -> String {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty else { return fallback }
    return String(value.prefix(limit))
  }

  private static func finiteNonnegative(_ value: Double?) -> Double {
    guard let value, value.isFinite, value >= 0 else { return 0 }
    return value
  }

  private static func isWebURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }

  private func scheduleTransportRefreshes() {
    timer?.invalidate()
    timer = nil
    transportRefreshTask?.cancel()
    transportRefreshTask = Task { [weak self] in
      for delay in Self.transportRefreshDelays {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
        guard let self, !Task.isCancelled else { return }
        self.refresh(priority: true)
      }
      self?.transportRefreshTask = nil
    }
  }
}

enum MusicControl: Equatable, Sendable {
  case playPause
  case next
  case previous
  case seek(Double)
  case setShuffle(Bool)
  case setRepeat(MusicRepeatMode)
  case setFavorite(Bool)
}

enum MusicRepeatMode: String, Equatable, Sendable {
  case off, all, one

  /// Follows Music's own button: off, then all, then one.
  var next: MusicRepeatMode {
    switch self {
    case .off: .all
    case .all: .one
    case .one: .off
    }
  }
}

/// The native player operations, injectable so tests never script the
/// user's real Music or Spotify app.
struct NativePlayerClient: Sendable {
  var runningSources: @MainActor @Sendable () -> [MusicSource]
  var query: @Sendable ([MusicSource], TimeInterval) async -> MusicQueryBatch
  var control: @Sendable (MusicControl, MusicSource) async -> String?
  var artwork: @Sendable (String) async -> NativeArtworkResult
  var observesSystemNotifications = true

  static let live = NativePlayerClient(
    runningSources: {
      let running = Set(
        NSWorkspace.shared.runningApplications
          .filter { !$0.isTerminated }
          .compactMap(\.bundleIdentifier)
      )
      return MusicSource.nativeCases.filter { running.contains($0.bundleIdentifier) }
    },
    query: { await MusicScriptRunner.query(sources: $0, timeout: $1) },
    control: { await MusicScriptRunner.control($0, source: $1, timeout: 2) },
    artwork: { await MusicScriptRunner.appleMusicArtwork(trackID: $0, timeout: 4) }
  )
}

/// Runs native Music/Spotify controls one at a time, in order: each is a
/// separate `osascript` process, so unordered runs could finish out of order.
/// A seek merges into the command queued just before it only when that is a
/// seek for the same app, so scrubbing does not build a backlog yet never
/// jumps ahead of another command.
@MainActor
final class NativeControlQueue {
  typealias Run = @MainActor (MusicControl, MusicSource) async -> Void

  private final class SeekTarget {
    var position: Double
    init(_ position: Double) { self.position = position }
  }

  private var chain: Task<Void, Never>?
  private var generation = 0
  /// The most recently queued command, when it is a seek that has not started.
  private var openSeek: (target: SeekTarget, source: MusicSource)?

  func enqueue(_ control: MusicControl, source: MusicSource, run: @escaping Run) {
    if case .seek(let position) = control, let openSeek, openSeek.source == source {
      openSeek.target.position = position
      return
    }
    var seekTarget: SeekTarget?
    if case .seek(let position) = control { seekTarget = SeekTarget(position) }
    openSeek = seekTarget.map { ($0, source) }

    let generation = self.generation
    let previous = chain
    chain = Task { [weak self] in
      await previous?.value
      guard let self, generation == self.generation else { return }
      if let seekTarget, self.openSeek?.target === seekTarget { self.openSeek = nil }
      await run(seekTarget.map { .seek($0.position) } ?? control, source)
    }
  }

  /// Drops queued commands that have not started.
  func cancelPending() {
    generation &+= 1
    openSeek = nil
  }

  /// Waits for every queued command to finish. For tests.
  func drain() async {
    await chain?.value
  }
}

private struct PendingBrowserControl {
  let command: BrowserMediaCommand
  let position: Double?
}

private struct BrowserSession: Sendable {
  let snapshot: NowPlayingSnapshot
  let lastSeenAt: Date
  let timeout: TimeInterval
}

private enum BrowserMediaValidationError: LocalizedError {
  case invalidSession
  case invalidTitle
  case invalidURL

  var errorDescription: String? {
    switch self {
    case .invalidSession: "Browser media session ID is invalid."
    case .invalidTitle: "Browser media title is missing or too long."
    case .invalidURL: "Browser media URLs must use HTTP or HTTPS."
    }
  }
}

struct MusicQueryBatch: Sendable {
  let snapshots: [NowPlayingSnapshot]
  let errorMessage: String?
}

enum NativeArtworkResult: Equatable, Sendable {
  case artwork(Data)
  /// The track has no cover, or it stopped being the current track.
  case unavailable
  /// The player timed out or the script failed. A later poll retries.
  case failed
}

enum MusicScriptRunner {
  nonisolated static func query(
    sources: [MusicSource],
    timeout: TimeInterval
  ) async -> MusicQueryBatch {
    var snapshots: [NowPlayingSnapshot] = []
    var firstError: String?

    for source in sources {
      let result = await run(script: queryScript(for: source), timeout: timeout)
      if let snapshot = parse(result.output, source: source) {
        snapshots.append(snapshot)
      } else if firstError == nil {
        firstError = userFacingError(from: result)
      }
    }

    return MusicQueryBatch(
      snapshots: snapshots,
      errorMessage: firstError
    )
  }

  nonisolated static func control(
    _ control: MusicControl,
    source: MusicSource,
    timeout: TimeInterval
  ) async -> String? {
    let result = await run(script: controlScript(control, source: source), timeout: timeout)
    return result.exitStatus == 0 ? nil : userFacingError(from: result)
  }

  nonisolated static func controlScript(_ control: MusicControl, source: MusicSource) -> String {
    let command: String
    switch control {
    case .playPause: command = "playpause"
    case .next: command = "next track"
    case .previous: command = "previous track"
    case .seek(let position): command = "set player position to \(position)"
    case .setShuffle(let enabled): command = "set shuffle enabled to \(enabled)"
    case .setRepeat(let mode): command = "set song repeat to \(mode.rawValue)"
    // `pLov` is "favorited" in current Music and "loved" in older versions.
    case .setFavorite(let favorite): command = "set «class pLov» of current track to \(favorite)"
    }
    return "tell application id \"\(source.bundleIdentifier)\" to \(command)"
  }

  /// Reads the current Apple Music cover, but only while `trackID` is still
  /// the current track, so a cover is never stored under the wrong song.
  nonisolated static func appleMusicArtwork(
    trackID: String,
    timeout: TimeInterval
  ) async -> NativeArtworkResult {
    guard let trackID = validTrackID(trackID) else { return .unavailable }
    let script = """
      tell application id "\(MusicSource.appleMusic.bundleIdentifier)"
        if (player state as text) is "stopped" then return ""
        set activeTrack to current track
        if (persistent ID of activeTrack) is not "\(trackID)" then return ""
        if (count of artworks of activeTrack) is 0 then return ""
        return raw data of artwork 1 of activeTrack
      end tell
      """
    // Covers are printed as hex, so allow twice the decoded size limit.
    let result = await run(
      script: script,
      timeout: timeout,
      outputLimit: ArtworkLoader.maximumDownloadBytes * 2 + 1_024
    )
    if result.outputTooLarge { return .unavailable }
    guard result.exitStatus == 0 else { return .failed }
    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    if output.isEmpty { return .unavailable }
    guard let original = parseRawData(output) else { return .failed }
    // Keep a small thumbnail instead of the original, which is often close
    // to a megabyte. An undecodable cover will not improve on retry.
    return ArtworkLoader.thumbnailJPEG(from: original).map(NativeArtworkResult.artwork)
      ?? .unavailable
  }

  /// Decodes AppleScript's display form of raw data, `«data JPEGFFD8…»`: a
  /// four-character type code followed by the bytes in hexadecimal.
  nonisolated static func parseRawData(_ output: String) -> Data? {
    let bytes = Array(output.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    let prefix = Array("«data ".utf8)
    let suffix = Array("»".utf8)
    let typeCodeLength = 4
    guard bytes.count > prefix.count + typeCodeLength + suffix.count,
      bytes.starts(with: prefix), bytes.suffix(suffix.count).elementsEqual(suffix)
    else { return nil }
    let hex = bytes[(prefix.count + typeCodeLength)..<(bytes.count - suffix.count)]
    guard !hex.isEmpty, hex.count % 2 == 0,
      hex.count / 2 <= ArtworkLoader.maximumDownloadBytes
    else { return nil }

    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
      case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
      case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
      default: nil
      }
    }
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      guard let high = nibble(hex[index]), let low = nibble(hex[index + 1]) else { return nil }
      data.append(high << 4 | low)
      index += 2
    }
    return data
  }

  /// Apple Music persistent IDs are hexadecimal. Anything else is dropped
  /// before it can be placed in a script.
  nonisolated private static func validTrackID(_ value: String) -> String? {
    guard (1...32).contains(value.utf8.count),
      value.utf8.allSatisfy({ $0 < 0x80 && Character(UnicodeScalar($0)).isHexDigit })
    else { return nil }
    return value
  }

  nonisolated private static func queryScript(for source: MusicSource) -> String {
    let durationExpression: String
    let artworkExpression: String
    let trackLines: String
    let playerLines: String
    switch source {
    case .appleMusic:
      durationExpression = "(duration of activeTrack) as text"
      artworkExpression = "\"\""
      // Each optional field fails on its own: a stream item without an ID
      // loses only its cover, and one that cannot be favorited loses only
      // that button. `pLov` is "favorited" now and "loved" in older Music.
      trackLines = """
        try
              set trackID to (persistent ID of activeTrack) as text
            end try
            try
              set favoriteState to («class pLov» of activeTrack) as text
            end try
        """
      playerLines = """
        try
            set shuffleState to shuffle enabled as text
          end try
          try
            set repeatState to song repeat as text
          end try
        """
    case .spotify:
      // Spotify's dictionary has no such terms, so they must not appear in
      // its script at all; an unknown term fails compilation of everything.
      durationExpression = "((duration of activeTrack) / 1000) as text"
      artworkExpression = "(artwork url of activeTrack) as text"
      trackLines = ""
      playerLines = ""
    case .browser:
      return ""
    }

    return """
      tell application id "\(source.bundleIdentifier)"
        set playbackState to player state as text
        set trackID to ""
        set shuffleState to ""
        set repeatState to ""
        set favoriteState to ""
        \(playerLines)
        if playbackState is "stopped" then
          set outputValues to {playbackState, "", "", "", "0", "0", "", "", "", "", ""}
        else
          set activeTrack to current track
          \(trackLines)
          set outputValues to {playbackState, name of activeTrack, artist of activeTrack, album of activeTrack, \(durationExpression), (player position) as text, \(artworkExpression), trackID, shuffleState, repeatState, favoriteState}
        end if
      end tell
      set previousDelimiters to AppleScript's text item delimiters
      set AppleScript's text item delimiters to ASCII character 31
      set outputText to outputValues as text
      set AppleScript's text item delimiters to previousDelimiters
      return outputText
      """
  }

  nonisolated static func parse(
    _ output: String,
    source: MusicSource
  ) -> NowPlayingSnapshot? {
    let values =
      output
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: String(UnicodeScalar(31)))
    guard values.count >= 7 else { return nil }

    let state = values[0].lowercased()
    guard state != "stopped", !values[1].isEmpty else { return nil }

    return NowPlayingSnapshot(
      source: source,
      title: values[1],
      artist: values[2],
      album: values[3],
      isPlaying: state == "playing",
      duration: seconds(from: values[4]),
      position: seconds(from: values[5]),
      artworkURL: URL(string: values[6]),
      sourceName: source.displayName,
      sourceURL: nil,
      browserSessionID: nil,
      supportsPrevious: true,
      supportsNext: true,
      trackID: values.count >= 8 ? validTrackID(values[7]) : nil,
      shuffleEnabled: values.count >= 9 ? Bool(values[8]) : nil,
      repeatMode: values.count >= 10 ? MusicRepeatMode(rawValue: values[9]) : nil,
      isFavorite: values.count >= 11 ? Bool(values[10]) : nil
    )
  }

  /// AppleScript writes reals with the system decimal separator, so a
  /// comma-decimal locale reports "215,306". It never adds grouping separators.
  nonisolated private static func seconds(from text: String) -> Double {
    let value = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    return value.isFinite && value >= 0 ? value : 0
  }

  /// Runs one script without occupying a thread while it waits: the exit,
  /// the timeout, and both pipes each signal a latch instead of being polled.
  nonisolated static func run(
    script: String,
    timeout: TimeInterval,
    outputLimit: Int = 262_144
  ) async -> ScriptProcessResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let exited = AsyncLatch()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.terminationHandler = { _ in exited.open() }

    do {
      try process.run()
    } catch {
      return ScriptProcessResult(
        output: "",
        error: error.localizedDescription,
        exitStatus: -1,
        timedOut: false
      )
    }

    // Both pipes are drained while the script runs. A reply larger than the
    // pipe buffer would otherwise block osascript until the timeout.
    let output = PipeReader(standardOutput, limit: outputLimit)
    let errors = PipeReader(standardError, limit: 65_536)

    let timedOut = await !exited.wait(timeout: timeout)
    var didExit = !timedOut
    if timedOut {
      process.terminate()
      didExit = await exited.wait(timeout: 2)
    }

    let (outputData, outputTooLarge) = await output.finish()
    let (errorData, _) = await errors.finish()

    return ScriptProcessResult(
      output: outputTooLarge ? "" : String(decoding: outputData, as: UTF8.self),
      error: String(decoding: errorData, as: UTF8.self),
      exitStatus: timedOut || !didExit ? -1 : process.terminationStatus,
      timedOut: timedOut,
      outputTooLarge: outputTooLarge
    )
  }

  nonisolated private static func userFacingError(
    from result: ScriptProcessResult
  ) -> String? {
    if result.timedOut {
      return "The music app did not respond. NotchRouter will try again."
    }

    let error = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !error.isEmpty else { return nil }
    if error.contains("-1743")
      || error.localizedCaseInsensitiveContains("not authorized")
    {
      return
        "Allow music control in System Settings → Privacy & Security → Automation."
    }
    return error
  }
}

struct ScriptProcessResult: Sendable {
  let output: String
  let error: String
  let exitStatus: Int32
  let timedOut: Bool
  var outputTooLarge = false
}

/// A one-way gate that async callers can wait on with a deadline. Opening it
/// releases current and future waiters; a waiter whose deadline passes first
/// is released with `false`. No thread is held while waiting.
final class AsyncLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

  func open() {
    let released = lock.withLock {
      isOpen = true
      defer { waiters.removeAll() }
      return Array(waiters.values)
    }
    released.forEach { $0.resume(returning: true) }
  }

  /// Returns whether the latch opened before `timeout` elapsed.
  func wait(timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { continuation in
      let id = UUID()
      let alreadyOpen = lock.withLock {
        if isOpen { return true }
        waiters[id] = continuation
        return false
      }
      if alreadyOpen {
        continuation.resume(returning: true)
        return
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
        [self] in
        lock.withLock { waiters.removeValue(forKey: id) }?.resume(returning: false)
      }
    }
  }
}

/// Reads a pipe as data arrives, using a dispatch source rather than a
/// blocked thread. Bytes beyond `limit` are discarded, but still read, so the
/// writer is never blocked.
private final class PipeReader: @unchecked Sendable {
  private let lock = NSLock()
  private let done = AsyncLatch()
  private var data = Data()
  private var overflowed = false

  init(_ pipe: Pipe, limit: Int) {
    pipe.fileHandleForReading.readabilityHandler = { [self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        done.open()
        return
      }
      lock.withLock {
        guard !overflowed else { return }
        if chunk.count <= limit - data.count {
          data.append(chunk)
        } else {
          overflowed = true
          data = Data()
        }
      }
    }
  }

  /// Call after the process exits. The write end is then closed, so the
  /// reader reaches end of file promptly; the wait is bounded regardless.
  func finish() async -> (Data, overflowed: Bool) {
    _ = await done.wait(timeout: 2)
    return lock.withLock { (data, overflowed) }
  }
}
