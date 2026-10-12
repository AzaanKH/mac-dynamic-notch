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

  }
}

private struct StatusMenuView: View {
  let appDelegate: AppDelegate

  var body: some View {
    Button("Show Activity") {
      appDelegate.showNotch()
    }
    .keyboardShortcut("n", modifiers: .option)
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
    Button("Show System") {
      appDelegate.showSystem()
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
      appDelegate.showSettings()
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
