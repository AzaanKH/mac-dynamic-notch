import Foundation
import NotchRouterCore
import Testing

@Test
func browserMediaProtocolUsesStableSnakeCaseKeys() throws {
  let event = BrowserMediaEvent(
    kind: .update,
    sessionID: "chromium:3",
    browserName: "Google Chrome",
    title: "Video",
    isPlaying: true,
    supportsPrevious: false,
    supportsNext: true
  )

  let data = try JSONEncoder().encode(event)
  let object = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  #expect(object["session_id"] as? String == "chromium:3")
  #expect(object["browser_name"] as? String == "Google Chrome")
  #expect(object["is_playing"] as? Bool == true)
  #expect(object["supports_next"] as? Bool == true)
}

@Test
func browserBridgeResponseUsesBrowserCommandKeys() throws {
  let response = BrowserMediaBridgeResponse(
    status: "ok",
    sessionID: "chromium:3",
    command: .playPause
  )
  let data = try JSONEncoder().encode(response)
  let object = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: String]
  )
  #expect(object == [
    "status": "ok",
    "session_id": "chromium:3",
    "command": "play_pause",
  ])
}

@Test
func browserMediaValidationAllowsOnlyWebURLs() throws {
  let valid = BrowserMediaEvent(
    kind: .update,
    sessionID: "chromium:3",
    browserName: "Google Chrome",
    pageURL: URL(string: "https://example.com/watch"),
    artworkURL: URL(string: "http://example.com/cover.jpg")
  )
  #expect(try valid.validated() == valid)

  for url in [
    URL(string: "file:///tmp/cover.jpg")!,
    URL(string: "custom-scheme://example.com/cover.jpg")!,
  ] {
    #expect(throws: BrowserMediaEventValidationError.self) {
      try BrowserMediaEvent(
        kind: .update,
        sessionID: "chromium:3",
        browserName: "Google Chrome",
        artworkURL: url
      ).validated()
    }
  }
}

@Test
func browserDownloadProtocolUsesStableKeysAndISODate() throws {
  let endTime = Date(timeIntervalSince1970: 1_800_000_000)
  let event = BrowserDownloadEvent(
    kind: .update,
    downloadID: 42,
    browserName: "Google Chrome",
    displayName: "archive.zip",
    sourceHost: "example.com",
    bytesReceived: 512,
    totalBytes: 1_024,
    estimatedEndTime: endTime,
    state: .inProgress,
    isPaused: false,
    canResume: true
  )

  let data = try ActivityCoding.makeEncoder().encode(event)
  let object = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  #expect(object["download_id"] as? Int == 42)
  #expect(object["browser_name"] as? String == "Google Chrome")
  #expect(object["display_name"] as? String == "archive.zip")
  #expect(object["source_host"] as? String == "example.com")
  #expect(object["filename"] == nil)
  #expect(object["source_url"] == nil)
  #expect(object["bytes_received"] as? Int == 512)
  #expect(object["estimated_end_time"] is String)
  #expect(
    try ActivityCoding.makeDecoder().decode(BrowserDownloadEvent.self, from: data)
      == event
  )
}

@Test
func browserDownloadResponseUsesBrowserCommandKeys() throws {
  let response = BrowserDownloadBridgeResponse(
    status: "ok",
    command: BrowserDownloadCommand(downloadID: 7, action: .pause)
  )
  let data = try JSONEncoder().encode(response)
  let object = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  let command = try #require(object["command"] as? [String: Any])
  #expect(object["status"] as? String == "ok")
  #expect(command["download_id"] as? Int == 7)
  #expect(command["action"] as? String == "pause")
}

@Test
func browserDownloadValidationRejectsInvalidIdentityAndOversizedFields() {
  #expect(throws: BrowserDownloadValidationError.self) {
    try BrowserDownloadEvent(
      kind: .update,
      downloadID: -1,
      browserName: "Chrome"
    ).validated()
  }
  #expect(throws: BrowserDownloadValidationError.self) {
    try BrowserDownloadEvent(
      kind: .heartbeat,
      browserName: "   "
    ).validated()
  }
  #expect(throws: BrowserDownloadValidationError.self) {
    try BrowserDownloadEvent(
      kind: .update,
      downloadID: 1,
      browserName: "Chrome",
      displayName: String(repeating: "x", count: 4_097)
    ).validated()
  }
}

@Test
func browserSeekWireFormatAndLegacyCompatibility() throws {
  let legacy = Data(#"{"kind":"update","session_id":"old","browser_name":"Chrome"}"#.utf8)
  let event = try JSONDecoder().decode(BrowserMediaEvent.self, from: legacy)
  #expect(event.supportsSeeking == nil)
  #expect(event.playbackRate == nil)
  let modern = Data(#"{"kind":"update","session_id":"new","browser_name":"Chrome","supports_seeking":true,"playback_rate":1.5}"#.utf8)
  let updated = try JSONDecoder().decode(BrowserMediaEvent.self, from: modern)
  #expect(updated.supportsSeeking == true)
  #expect(updated.playbackRate == 1.5)
  let response = BrowserMediaBridgeResponse(
    status: "ok", sessionID: "new", command: .seek, seekPosition: 42.5
  )
  let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
  #expect(object["command"] as? String == "seek")
  #expect(object["seek_position"] as? Double == 42.5)
  #expect(object["session_id"] as? String == "new")
}

@Test
func browserArtworkBytesHaveAnExplicitWireLimit() throws {
  let data = Data([1, 2, 3])
  let event = BrowserMediaEvent(kind: .update, sessionID: "test", browserName: "Browser", artworkData: data)
  let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
  #expect(json["artwork_data"] as? String == "AQID")
  #expect(throws: BrowserMediaEventValidationError.self) {
    try BrowserMediaEvent(kind: .update, sessionID: "test", browserName: "Browser", artworkData: Data(repeating: 1, count: 32769)).validated()
  }
}

@Test
func backgroundFlagDecodesAndStaysOptionalForOlderExtensions() throws {
  let decoder = JSONDecoder()
  let hidden = try decoder.decode(BrowserMediaEvent.self, from: Data(#"""
    {"kind":"update","session_id":"s","browser_name":"Chrome","title":"T","is_background":true}
    """#.utf8))
  #expect(hidden.isBackground == true)

  let legacy = try decoder.decode(BrowserMediaEvent.self, from: Data(#"""
    {"kind":"update","session_id":"s","browser_name":"Chrome","title":"T"}
    """#.utf8))
  #expect(legacy.isBackground == nil)
}
