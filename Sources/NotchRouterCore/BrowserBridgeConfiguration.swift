import Foundation

public enum BrowserBridgeConfiguration {
  public static let hostName = "com.notchrouter.browser_media"
  public static let chromiumExtensionID = "eelhjoihmcccgbleiekmpeabeijcemkb"
  public static let firefoxExtensionID = "browser-bridge@notchrouter.local"
  public static let chromiumManifestDirectories = [
    "Google/Chrome/NativeMessagingHosts",
    "Microsoft Edge/NativeMessagingHosts",
    "BraveSoftware/Brave-Browser/NativeMessagingHosts",
    "Chromium/NativeMessagingHosts",
  ]
  public static let firefoxManifestDirectory = "Mozilla/NativeMessagingHosts"
  public static var manifestDirectories: [String] {
    chromiumManifestDirectories + [firefoxManifestDirectory]
  }

  public static func nativeHostManifest(hostURL: URL, forFirefox: Bool) throws -> Data {
    var manifest: [String: Any] = [
      "name": hostName,
      "description": "Passes browser media and opted-in download status to NotchRouter.",
      "path": hostURL.path,
      "type": "stdio",
    ]
    if forFirefox {
      manifest["allowed_extensions"] = [firefoxExtensionID]
    } else {
      manifest["allowed_origins"] = ["chrome-extension://\(chromiumExtensionID)/"]
    }
    var data = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
    )
    data.append(0x0A)
    return data
  }
}
