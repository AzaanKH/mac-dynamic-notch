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
