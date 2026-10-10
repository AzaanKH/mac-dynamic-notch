import Foundation
import Testing
@testable import NotchRouterCore

@Test
func nativeHostManifestsUseBrowserSpecificAllowlists() throws {
  let hostURL = URL(fileURLWithPath: "/tmp/notch-test-host")
  let chromiumData = try BrowserBridgeConfiguration.nativeHostManifest(hostURL: hostURL, forFirefox: false)
  let firefoxData = try BrowserBridgeConfiguration.nativeHostManifest(hostURL: hostURL, forFirefox: true)
  let chromium = try #require(JSONSerialization.jsonObject(with: chromiumData) as? [String: Any])
  let firefox = try #require(JSONSerialization.jsonObject(with: firefoxData) as? [String: Any])
  #expect(chromium["allowed_origins"] as? [String] == ["chrome-extension://eelhjoihmcccgbleiekmpeabeijcemkb/"])
  #expect(chromium["allowed_extensions"] == nil)
  #expect(firefox["allowed_extensions"] as? [String] == ["browser-bridge@notchrouter.local"])
  #expect(firefox["allowed_origins"] == nil)
  #expect(firefox["path"] as? String == hostURL.path)
  #expect(firefox["type"] as? String == "stdio")

  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let extensionManifest = try #require(JSONSerialization.jsonObject(
    with: Data(contentsOf: repository.appendingPathComponent("BrowserExtension/manifest.json"))
  ) as? [String: Any])
  let settings = try #require(extensionManifest["browser_specific_settings"] as? [String: Any])
  let gecko = try #require(settings["gecko"] as? [String: Any])
  let extensionID = try #require(gecko["id"] as? String)
  #expect(firefox["allowed_extensions"] as? [String] == [extensionID])
}
