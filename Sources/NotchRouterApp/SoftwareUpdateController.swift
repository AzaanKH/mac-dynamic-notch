import AppKit
import Sparkle

@MainActor
final class SoftwareUpdateController {
  private let controller: SPUStandardUpdaterController?

  var isConfigured: Bool {
    controller != nil
  }

  init(bundle: Bundle = .main) {
    let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
    let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String

    guard
      let feedURL,
      URL(string: feedURL)?.scheme == "https",
      let publicKey,
      !publicKey.isEmpty
    else {
      controller = nil
      return
    }

    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }
}
