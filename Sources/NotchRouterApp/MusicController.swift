import AppKit
import Combine
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
final class MusicController: NSObject, ObservableObject {
  static let preferenceKey = "musicIntegrationEnabled"
  static let playingPollInterval: TimeInterval = 8
  static let inactivePollInterval: TimeInterval = 30
  static let transportRefreshDelays: [Duration] = [
    .milliseconds(120),
    .milliseconds(480),
  ]
  static let browserSessionTimeout: TimeInterval = 12

  @Published private(set) var isEnabled: Bool
  @Published private(set) var nowPlaying: NowPlayingSnapshot?
  @Published private(set) var permissionMessage: String?

  let systemVolume = SystemVolumeController()

  var onChange: ((MusicPresentationEvent) -> Void)?

  private var timer: Timer?
  private var browserExpiryTimer: Timer?
  private var refreshTask: Task<Void, Never>?
  private var transportRefreshTask: Task<Void, Never>?
  private var refreshAfterCurrentTask = false
  private var nativeSnapshots: [NowPlayingSnapshot] = []
  private var browserSessions: [String: BrowserSession] = [:]
  private var pendingBrowserCommands: [String: [BrowserMediaCommand]] = [:]
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.bool(forKey: Self.preferenceKey)
    super.init()
    if isEnabled {
      refresh()
    }
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.preferenceKey)
    permissionMessage = nil

    if enabled {
      refresh(allowsPermissionPrompt: true)
    } else {
      stopPolling()
      refreshTask?.cancel()
      refreshTask = nil
      transportRefreshTask?.cancel()
      transportRefreshTask = nil
      refreshAfterCurrentTask = false
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

    let runningSources = MusicSource.nativeCases.filter(isRunning)
    guard !runningSources.isEmpty else {
      apply(MusicQueryBatch(snapshots: [], errorMessage: nil))
      return
    }

    refreshTask = Task { [weak self] in
      let timeout = allowsPermissionPrompt ? 15.0 : 2.0
      let batch = await MusicScriptRunner.query(
        sources: runningSources,
        timeout: timeout
      )
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
    executeControl(.playPause)
  }

  func nextTrack() {
    executeControl(.next)
  }

  func previousTrack() {
    executeControl(.previous)
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
      let snapshot = try Self.browserSnapshot(from: event)
      browserSessions[event.sessionID] = BrowserSession(
        snapshot: snapshot,
        lastSeenAt: now
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
      command: command
    )
  }

  var hasBrowserSession: Bool {
    !browserSessions.isEmpty
  }

  static func pollInterval(
    for snapshot: NowPlayingSnapshot?
  ) -> TimeInterval {
    snapshot?.isPlaying == true
      ? playingPollInterval
      : inactivePollInterval
  }

  private func scheduleNextPoll() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(
      timeInterval: Self.pollInterval(for: nowPlaying),
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
        .map({ $0.lastSeenAt.addingTimeInterval(Self.browserSessionTimeout) })
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

  private func isRunning(_ source: MusicSource) -> Bool {
    NSWorkspace.shared.runningApplications.contains {
      $0.bundleIdentifier == source.bundleIdentifier
    }
  }

  private func apply(_ batch: MusicQueryBatch) {
    nativeSnapshots = batch.snapshots
    selectNowPlaying()
    permissionMessage = nowPlaying == nil ? batch.errorMessage : nil
    scheduleNextPoll()
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

    if let event = Self.presentationEvent(
      from: oldSnapshot,
      to: nowPlaying
    ) {
      onChange?(event)
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
      || oldSnapshot.sourceURL != newSnapshot.sourceURL
    return contentChanged ? .contentChanged : nil
  }

  private func executeControl(_ control: MusicControl) {
    if nowPlaying?.source == .browser {
      executeBrowserControl(control)
      return
    }
    let source =
      nowPlaying?.source
      ?? MusicSource.nativeCases.first(where: isRunning)
    guard let source else { return }
    let requestsPeek =
      control == .next
      || control == .previous
      || (control == .playPause && nowPlaying?.isPlaying != true)

    Task { [weak self] in
      let error = await MusicScriptRunner.control(
        control,
        source: source,
        timeout: 2
      )
      guard let self, !Task.isCancelled else { return }
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
    switch control {
    case .playPause:
      command = .playPause
    case .previous:
      guard snapshot.supportsPrevious else { return }
      command = .previous
    case .next:
      guard snapshot.supportsNext else { return }
      command = .next
    }
    var commands = pendingBrowserCommands[sessionID] ?? []
    if commands.count < 8 {
      commands.append(command)
      pendingBrowserCommands[sessionID] = commands
    }

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
      now.timeIntervalSince(session.lastSeenAt) > Self.browserSessionTimeout
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
      artworkURL: event.artworkURL,
      sourceName: siteName,
      sourceURL: event.pageURL,
      browserSessionID: sessionID,
      supportsPrevious: event.supportsPrevious ?? false,
      supportsNext: event.supportsNext ?? false
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

private enum MusicControl: Equatable, Sendable {
  case playPause
  case next
  case previous
}

private struct BrowserSession: Sendable {
  let snapshot: NowPlayingSnapshot
  let lastSeenAt: Date
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

private struct MusicQueryBatch: Sendable {
  let snapshots: [NowPlayingSnapshot]
  let errorMessage: String?
}

private enum MusicScriptRunner {
  nonisolated static func query(
    sources: [MusicSource],
    timeout: TimeInterval
  ) async -> MusicQueryBatch {
    var snapshots: [NowPlayingSnapshot] = []
    var firstError: String?

    for source in sources {
      let result = run(script: queryScript(for: source), timeout: timeout)
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
    let command: String
    switch control {
    case .playPause: command = "playpause"
    case .next: command = "next track"
    case .previous: command = "previous track"
    }

    let result = run(
      script: "tell application id \"\(source.bundleIdentifier)\" to \(command)",
      timeout: timeout
    )
    return result.exitStatus == 0 ? nil : userFacingError(from: result)
  }

  nonisolated private static func queryScript(for source: MusicSource) -> String {
    let durationExpression: String
    let artworkExpression: String
    switch source {
    case .appleMusic:
      durationExpression = "(duration of activeTrack) as text"
      artworkExpression = "\"\""
    case .spotify:
      durationExpression = "((duration of activeTrack) / 1000) as text"
      artworkExpression = "(artwork url of activeTrack) as text"
    case .browser:
      return ""
    }

    return """
      tell application id "\(source.bundleIdentifier)"
        set playbackState to player state as text
        if playbackState is "stopped" then
          set outputValues to {playbackState, "", "", "", "0", "0", ""}
        else
          set activeTrack to current track
          set outputValues to {playbackState, name of activeTrack, artist of activeTrack, album of activeTrack, \(durationExpression), (player position) as text, \(artworkExpression)}
        end if
      end tell
      set previousDelimiters to AppleScript's text item delimiters
      set AppleScript's text item delimiters to ASCII character 31
      set outputText to outputValues as text
      set AppleScript's text item delimiters to previousDelimiters
      return outputText
      """
  }

  nonisolated private static func parse(
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
      duration: Double(values[4]) ?? 0,
      position: Double(values[5]) ?? 0,
      artworkURL: URL(string: values[6]),
      sourceName: source.displayName,
      sourceURL: nil,
      browserSessionID: nil,
      supportsPrevious: true,
      supportsNext: true
    )
  }

  nonisolated private static func run(
    script: String,
    timeout: TimeInterval
  ) -> ScriptProcessResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.standardOutput = standardOutput
    process.standardError = standardError

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

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.04)
    }

    let timedOut = process.isRunning
    if timedOut {
      process.terminate()
      process.waitUntilExit()
    }

    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()

    return ScriptProcessResult(
      output: String(decoding: outputData, as: UTF8.self),
      error: String(decoding: errorData, as: UTF8.self),
      exitStatus: timedOut ? -1 : process.terminationStatus,
      timedOut: timedOut
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

private struct ScriptProcessResult: Sendable {
  let output: String
  let error: String
  let exitStatus: Int32
  let timedOut: Bool
}
