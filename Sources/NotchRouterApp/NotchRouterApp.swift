import SwiftUI

@main
struct NotchRouterApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  init() {
    CrashReporter.start()
  }

  var body: some Scene {
    MenuBarExtra(
      "NotchRouter",
      systemImage: "sparkles.rectangle.stack"
    ) {
      StatusMenuView(appDelegate: appDelegate)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsRootView(appDelegate: appDelegate)
    }
    .defaultSize(width: 680, height: 540)
    .windowResizability(.contentSize)
  }
}

private struct StatusMenuView: View {
  @ObservedObject var appDelegate: AppDelegate
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("Show Activity") {
      appDelegate.showNotch()
    }
    .keyboardShortcut(.space, modifiers: .option)
    Button("Show Files") {
      appDelegate.showFiles()
    }
    Button("Show Focus Timer") {
      appDelegate.showFocus()
    }
    Button("Show Music") {
      appDelegate.showMusic()
    }
    Button("Show Clipboard") {
      appDelegate.showClipboard()
    }
    Button("Send Demo Activity") {
      appDelegate.sendDemoActivity()
    }
    Button("Check for Updates…") {
      appDelegate.checkForUpdates()
    }
    .disabled(!appDelegate.canCheckForUpdates)
    Divider()
    Button("Settings…") {
      NSApp.activate(ignoringOtherApps: true)
      openSettings()
    }
    .keyboardShortcut(",", modifiers: .command)
    Button("Open Data Folder") {
      appDelegate.openDataFolder()
    }
    Divider()
    Button("Quit NotchRouter") {
      appDelegate.quit()
    }
    .keyboardShortcut("q", modifiers: .command)
  }
}
