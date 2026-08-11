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
func browserBridgeResponseRoundTripsACommand() throws {
  let response = BrowserMediaBridgeResponse(
    status: "ok",
    sessionID: "chromium:3",
    command: .next
  )
  let data = try JSONEncoder().encode(response)
  let decoded = try JSONDecoder().decode(
    BrowserMediaBridgeResponse.self,
    from: data
  )

  #expect(decoded == response)
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
    filename: "/Users/test/Downloads/archive.zip",
    sourceURL: "https://example.com/archive.zip",
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
  #expect(object["bytes_received"] as? Int == 512)
  #expect(object["estimated_end_time"] is String)
  #expect(
    try ActivityCoding.makeDecoder().decode(BrowserDownloadEvent.self, from: data)
      == event
  )
}

@Test
func browserDownloadResponseRoundTripsACommand() throws {
  let response = BrowserDownloadBridgeResponse(
    status: "ok",
    command: BrowserDownloadCommand(downloadID: 7, action: .pause)
  )
  let data = try JSONEncoder().encode(response)
  #expect(
    try JSONDecoder().decode(BrowserDownloadBridgeResponse.self, from: data)
      == response
  )
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
      filename: String(repeating: "x", count: 4_097)
    ).validated()
  }
}
