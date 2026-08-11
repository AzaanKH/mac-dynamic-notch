import AppKit
import Carbon.HIToolbox
import Combine
import NotchRouterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  @Published private(set) var settingsDependencies: SettingsDependencies?

  private var store: ActivityStore!
  private var fileShelf: FileShelfStore!
  private var downloads: BrowserDownloadStore!
  private var battery: BatteryMonitor!
  private var clipboard: ClipboardStore!
  private var music: MusicController!
  private var focusTimer: FocusTimerController!
  private var systemMonitor: SystemMonitorController!
  private var panelController: NotchPanelController!
  private var server: ActivityHTTPServer?
  private var notificationService: ActivityNotificationService!
  private var launchAtLogin: LaunchAtLoginController!
  private var displaySelection: DisplaySelectionController!
  private var integrations: IntegrationSettingsController!
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
    downloads = BrowserDownloadStore()
    battery = BatteryMonitor()
    clipboard = ClipboardStore()
    music = MusicController()
    focusTimer = FocusTimerController()
    systemMonitor = SystemMonitorController()
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
      },
      browserDownloadHandler: { [weak downloads] event in
        try await MainActor.run {
          guard let downloads else {
            throw AppRuntimeError.storeUnavailable
          }
          return try downloads.ingest(event)
        }
      }
    )
    self.server = server

    panelController = NotchPanelController(
      store: store,
      fileShelf: fileShelf,
      downloads: downloads,
      battery: battery,
      clipboard: clipboard,
      music: music,
      focusTimer: focusTimer,
      notificationService: notificationService,
      server: server,
      systemMonitor: systemMonitor,
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
      systemMonitor: systemMonitor,
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

  func showNotch() {
    panelController.show(.activity)
  }

  @objc private func expireStaleActivities() {
    guard store.expireStaleActivities() else { return }
    panelController.refreshLayout()
  }

  func showFiles() {
    panelController.show(.files)
  }

  func showFocus() {
    panelController.show(.focus)
  }

  func showMusic() {
    panelController.show(.music)
  }

  func showClipboard() {
    panelController.show(.clipboard)
  }

  func sendDemoActivity() {
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

  var canCheckForUpdates: Bool {
    softwareUpdater?.isConfigured == true
  }

  func checkForUpdates() {
    softwareUpdater.checkForUpdates()
  }

  func openDataFolder() {
    NSWorkspace.shared.open(AppPaths.applicationSupportDirectory)
  }

  func quit() {
    NSApp.terminate(nil)
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
