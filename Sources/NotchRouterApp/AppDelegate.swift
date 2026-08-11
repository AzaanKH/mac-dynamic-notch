import AppKit
import Carbon.HIToolbox
import Combine
import NotchRouterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  @Published private(set) var settingsDependencies: SettingsDependencies?

  private var store: ActivityStore!
  private var fileShelf: FileShelfStore!
  private var clipboard: ClipboardStore!
  private var music: MusicController!
  private var focusTimer: FocusTimerController!
  private var panelController: NotchPanelController!
  private var server: ActivityHTTPServer?
  private var notificationService: ActivityNotificationService!
  private var launchAtLogin: LaunchAtLoginController!
  private var displaySelection: DisplaySelectionController!
  private var integrations: IntegrationSettingsController!
  private var statusItem: NSStatusItem!
  private var globalHotKey: GlobalHotKey?
  private var integrationToken = ""
  private var softwareUpdater: SoftwareUpdateController!
  private var instanceGuard: SingleInstanceGuard?
  private var showRequestObserver: NSObjectProtocol?
  private var activityExpiryTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    do {
      guard let instanceGuard = try SingleInstanceGuard.acquire() else {
        DistributedNotificationCenter.default().postNotificationName(
          SingleInstanceGuard.showRequest,
          object: nil,
          deliverImmediately: true
        )
        NSApp.terminate(nil)
        return
      }
      self.instanceGuard = instanceGuard
    } catch {
      presentFatalError(error)
      return
    }

    do {
      integrationToken = try IntegrationToken.loadOrCreate()
    } catch {
      presentFatalError(error)
      return
    }

    store = ActivityStore()
    fileShelf = FileShelfStore()
    clipboard = ClipboardStore()
    music = MusicController()
    focusTimer = FocusTimerController()
    notificationService = ActivityNotificationService()
    softwareUpdater = SoftwareUpdateController()
    launchAtLogin = LaunchAtLoginController()
    displaySelection = DisplaySelectionController()

    let server = ActivityHTTPServer(
      token: integrationToken,
      ingestHandler: { [weak store] event in
        try await MainActor.run {
          guard let store else {
            throw AppRuntimeError.storeUnavailable
          }
          return try store.ingest(event)
        }
      },
      listHandler: { [weak store] in
        await MainActor.run { store?.activities ?? [] }
      },
      browserMediaHandler: { [weak music] event in
        try await MainActor.run {
          guard let music else {
            throw AppRuntimeError.storeUnavailable
          }
          return try music.ingestBrowserMedia(event)
        }
      }
    )
    self.server = server

    panelController = NotchPanelController(
      store: store,
      fileShelf: fileShelf,
      clipboard: clipboard,
      music: music,
      focusTimer: focusTimer,
      notificationService: notificationService,
      server: server,
      displaySelection: displaySelection
    )

    integrations = IntegrationSettingsController(
      token: integrationToken,
      server: server,
      clipboard: clipboard
    )
    settingsDependencies = SettingsDependencies(
      launchAtLogin: launchAtLogin,
      displaySelection: displaySelection,
      activityStore: store,
      clipboard: clipboard,
      music: music,
      notifications: notificationService,
      server: server,
      integrations: integrations
    )

    showRequestObserver = DistributedNotificationCenter.default().addObserver(
      forName: SingleInstanceGuard.showRequest,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.panelController.show()
      }
    }

    let existingIngest = store.onIngest
    store.onIngest = { [weak self] activity in
      existingIngest?(activity)
      self?.notificationService.deliverIfImportant(activity)
    }

    server.start()

    let activityExpiryTimer = Timer(
      timeInterval: ActivityStore.expiryCheckInterval,
      target: self,
      selector: #selector(expireStaleActivities),
      userInfo: nil,
      repeats: true
    )
    RunLoop.main.add(activityExpiryTimer, forMode: .common)
    self.activityExpiryTimer = activityExpiryTimer

    configureGlobalShortcut()
    configureStatusItem()
  }

  func applicationWillTerminate(_ notification: Notification) {
    activityExpiryTimer?.invalidate()
    activityExpiryTimer = nil
    server?.stop()
    if let showRequestObserver {
      DistributedNotificationCenter.default().removeObserver(showRequestObserver)
    }
    showRequestObserver = nil
    globalHotKey = nil
    instanceGuard = nil
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    launchAtLogin?.refresh()
    displaySelection?.refreshDisplays()
  }

  @objc private func showNotch() {
    panelController.show(.activity)
  }

  @objc private func expireStaleActivities() {
    guard store.expireStaleActivities() else { return }
    panelController.refreshLayout()
  }

  @objc private func showFiles() {
    panelController.show(.files)
  }

  @objc private func showFocus() {
    panelController.show(.focus)
  }

  @objc private func showMusic() {
    panelController.show(.music)
  }

  @objc private func showClipboard() {
    panelController.show(.clipboard)
  }

  @objc private func sendDemoActivity() {
    let event = ActivityEventRequest(
      activityID: "notchrouter-demo",
      source: "Demo Agent",
      title: "Preparing a release summary",
      state: .running,
      message: "Reading recent changes and grouping them by feature.",
      progress: 0.42
    )
    _ = try? store.ingest(event)
  }

  @objc private func checkForUpdates() {
    softwareUpdater.checkForUpdates()
  }

  @objc private func showSettings() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.sendAction(
      Selector(("showSettingsWindow:")),
      to: nil,
      from: nil
    )
  }

  @objc private func openDataFolder() {
    NSWorkspace.shared.open(AppPaths.applicationSupportDirectory)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func configureStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "sparkles.rectangle.stack",
      accessibilityDescription: "NotchRouter"
    )

    let menu = NSMenu()
    let showItem = menu.addItem(
      withTitle: "Show Activity",
      action: #selector(showNotch),
      keyEquivalent: " "
    )
    showItem.keyEquivalentModifierMask = [.option]
    menu.addItem(
      withTitle: "Show Files",
      action: #selector(showFiles),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Show Focus Timer",
      action: #selector(showFocus),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Show Music",
      action: #selector(showMusic),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Show Clipboard",
      action: #selector(showClipboard),
      keyEquivalent: ""
    )
    menu.addItem(
      withTitle: "Send Demo Activity",
      action: #selector(sendDemoActivity),
      keyEquivalent: ""
    )
    let updateItem = menu.addItem(
      withTitle: "Check for Updates…",
      action: #selector(checkForUpdates),
      keyEquivalent: ""
    )
    updateItem.isEnabled = softwareUpdater.isConfigured
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Settings…",
      action: #selector(showSettings),
      keyEquivalent: ","
    )
    menu.addItem(
      withTitle: "Open Data Folder",
      action: #selector(openDataFolder),
      keyEquivalent: ""
    )
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit NotchRouter",
      action: #selector(quit),
      keyEquivalent: "q"
    )

    for item in menu.items {
      item.target = self
    }
    statusItem.menu = menu
  }

  private func configureGlobalShortcut() {
    do {
      globalHotKey = try GlobalHotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey)
      ) { [weak self] in
        self?.panelController.show(.activity)
      }
    } catch {
      NSLog("NotchRouter global shortcut unavailable: %@", error.localizedDescription)
    }
  }

  private func presentFatalError(_ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "NotchRouter could not start"
    alert.informativeText = error.localizedDescription
    alert.runModal()
    NSApp.terminate(nil)
  }
}

private enum AppRuntimeError: LocalizedError {
  case storeUnavailable

  var errorDescription: String? {
    "The activity store is unavailable."
  }
}
