import SwiftUI

@main
struct NotchRouterApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  init() {
    CrashReporter.start()
  }

  var body: some Scene {
    Settings {
      SettingsRootView(appDelegate: appDelegate)
    }
    .defaultSize(width: 680, height: 540)
    .windowResizability(.contentSize)
  }
}
