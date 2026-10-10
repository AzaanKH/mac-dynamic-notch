import AppKit
import ColorSync
import Observation
import Foundation
import NotchRouterCore
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
  private(set) var isEnabled = false
  private(set) var isAvailable = false
  private(set) var statusMessage: String?

  init() {
    refresh()
  }

  func setEnabled(_ enabled: Bool) {
    guard isAvailable else { return }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      refresh()
    } catch {
      updateStatus()
      statusMessage = error.localizedDescription
    }
  }

  func refresh() {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      isAvailable = false
      isEnabled = false
      statusMessage = "Launch at login is available in the packaged app."
      return
    }
    isAvailable = true
    updateStatus()
  }

  func openLoginItemsSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func updateStatus() {
    switch SMAppService.mainApp.status {
    case .enabled:
      isEnabled = true
      statusMessage = nil
    case .requiresApproval:
      isEnabled = true
      statusMessage = "Approve NotchRouter in System Settings → Login Items."
    case .notRegistered:
      isEnabled = false
      statusMessage = nil
    case .notFound:
      isEnabled = false
      statusMessage = "macOS could not find this app's login item registration."
    @unknown default:
      isEnabled = false
      statusMessage = "The login item status is unavailable."
    }
  }
}

struct DisplayOption: Identifiable, Equatable {
  let id: String
  let name: String
  let detail: String
  let isMain: Bool
}

enum DisplayBehavior: String, CaseIterable, Identifiable {
  case pointer
  case activeWindow
  case pinned

  var id: String { rawValue }
}

@MainActor
@Observable
final class DisplaySelectionController {
  static let automaticIdentifier = "automatic"
  static let preferenceKey = "preferredDisplayIdentifier"
  static let behaviorPreferenceKey = "displayBehavior"
  static let hideOnExternalDisplaysPreferenceKey =
    "hideSoftwareNotchOnExternalDisplays"

  private(set) var displays: [DisplayOption] = []
  private(set) var behavior: DisplayBehavior
  private(set) var pinnedDisplayIdentifier: String?
  private(set) var hidesOnExternalDisplays: Bool

  var onSelectionChange: (() -> Void)?

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let storedDisplayIdentifier = defaults.string(forKey: Self.preferenceKey)
    let preferredDisplayIdentifier =
      storedDisplayIdentifier == Self.automaticIdentifier
      ? nil
      : storedDisplayIdentifier
    pinnedDisplayIdentifier = preferredDisplayIdentifier
    if let storedBehavior = defaults.string(forKey: Self.behaviorPreferenceKey),
      let behavior = DisplayBehavior(rawValue: storedBehavior)
    {
      self.behavior = behavior
    } else {
      behavior = preferredDisplayIdentifier == nil ? .pointer : .pinned
    }
    hidesOnExternalDisplays = defaults.bool(
      forKey: Self.hideOnExternalDisplaysPreferenceKey
    )
    if storedDisplayIdentifier == Self.automaticIdentifier {
      defaults.removeObject(forKey: Self.preferenceKey)
    }
    refreshDisplays()
  }

  func setBehavior(_ behavior: DisplayBehavior) {
    guard behavior != self.behavior else { return }
    self.behavior = behavior
    defaults.set(behavior.rawValue, forKey: Self.behaviorPreferenceKey)
    if behavior == .pinned,
      pinnedDisplayIdentifier == nil,
      let defaultIdentifier = displays.first(where: \.isMain)?.id ?? displays.first?.id
    {
      setPinnedDisplay(defaultIdentifier)
      return
    }
    onSelectionChange?()
  }

  func setPinnedDisplay(_ identifier: String?) {
    guard identifier != pinnedDisplayIdentifier else { return }
    pinnedDisplayIdentifier = identifier
    if let identifier {
      defaults.set(identifier, forKey: Self.preferenceKey)
    } else {
      defaults.removeObject(forKey: Self.preferenceKey)
    }
    onSelectionChange?()
  }

  func setHidesOnExternalDisplays(_ hides: Bool) {
    guard hides != hidesOnExternalDisplays else { return }
    hidesOnExternalDisplays = hides
    defaults.set(hides, forKey: Self.hideOnExternalDisplaysPreferenceKey)
    onSelectionChange?()
  }

  func refreshDisplays() {
    displays = NSScreen.screens.compactMap { screen in
      guard let identifier = Self.identifier(for: screen) else { return nil }
      let width = Int(screen.frame.width.rounded())
      let height = Int(screen.frame.height.rounded())
      return DisplayOption(
        id: identifier,
        name: screen.localizedName,
        detail: "\(width) × \(height)",
        isMain: screen == NSScreen.main
      )
    }
    if behavior == .pinned,
      pinnedDisplayIdentifier == nil,
      let defaultIdentifier = displays.first(where: \.isMain)?.id ?? displays.first?.id
    {
      setPinnedDisplay(defaultIdentifier)
    }
  }

  func selectedScreen() -> NSScreen? {
    guard behavior == .pinned, let pinnedDisplayIdentifier else { return nil }
    return NSScreen.screens.first {
      Self.identifier(for: $0) == pinnedDisplayIdentifier
    }
  }

  func containsSelectedDisplay() -> Bool {
    guard let pinnedDisplayIdentifier else { return false }
    return displays.contains { $0.id == pinnedDisplayIdentifier }
  }

  private static func identifier(for screen: NSScreen) -> String? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    guard let number = screen.deviceDescription[key] as? NSNumber else {
      return nil
    }
    guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) else {
      return number.stringValue
    }
    let uuid = unmanagedUUID.takeRetainedValue()
    return CFUUIDCreateString(nil, uuid) as String
  }
}

@MainActor
@Observable
final class IntegrationSettingsController {
  private(set) var token: String
  private(set) var operationMessage: String?
  private(set) var isRunningCodexSetup = false
  private(set) var codexHooksInstalled = false
  private(set) var browserOperationMessage: String?
  private(set) var isRunningBrowserSetup = false
  private(set) var browserExtensionInstalled = false
  /// Installed integrations keep running the helper copied at install time.
  /// After an app update that copy can be outdated (for example still using
  /// TCP), so offer an explicit update instead of failing silently.
  private(set) var codexHooksNeedUpdate = false
  private(set) var browserBridgeNeedsUpdate = false
  // Comparisons run in the background; only the newest result may publish,
  // so a check that started before an install or removal cannot win.
  @ObservationIgnored private var codexHelperCheck = 0
  @ObservationIgnored private var browserHelperCheck = 0

  let endpoint: String

  private let server: ActivityHTTPServer
  private let clipboard: ClipboardStore

  init(
    token: String,
    server: ActivityHTTPServer,
    clipboard: ClipboardStore
  ) {
    self.token = token
    self.server = server
    self.clipboard = clipboard
    endpoint = "http://localhost/v1/activities"
    refreshCodexHookStatus()
    refreshBrowserExtensionStatus()
  }

  func copyToken() {
    clipboard.copySensitive(token)
    operationMessage = "Integration token copied without adding it to history."
  }

  func copyEndpoint() {
    clipboard.copySensitive(endpoint)
    operationMessage = "Local endpoint copied."
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  func copyExampleRequest() {
    let request = """
      curl --unix-socket \(Self.shellQuote(LocalAPISocket.url.path)) -X POST \(endpoint) \\
        -H 'Authorization: Bearer \(token)' \\
        -H 'Content-Type: application/json' \\
        -d '{"activity_id":"example","source":"My Agent","title":"Working","state":"running"}'
      """
    clipboard.copySensitive(request)
    operationMessage = "Example request copied without adding it to history."
  }

  func rotateToken() {
    do {
      let newToken = try IntegrationToken.rotate()
      token = newToken
      server.updateToken(newToken)
      clipboard.copySensitive(newToken)
      operationMessage =
        "Token rotated and copied. Existing third-party clients must use the new token."
    } catch {
      operationMessage = "Could not rotate the token: \(error.localizedDescription)"
    }
  }

  func setLegacyTCPEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: "legacyTCPAPIEnabled")
    server.setLegacyTCPEnabled(enabled)
  }

  func retryServer() {
    server.start()
  }

  func installCodexHooks() {
    runCodexSetup(command: "install-codex-hooks")
  }

  func removeCodexHooks() {
    runCodexSetup(command: "remove-codex-hooks")
  }

  func installBrowserExtension() {
    runBrowserSetup(command: "install-browser-extension")
  }

  func removeBrowserExtension() {
    runBrowserSetup(command: "remove-browser-extension")
  }

  func openBrowserExtensionFolder() {
    let directory = AppPaths.applicationSupportDirectory
      .appendingPathComponent("browser-extension", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      browserOperationMessage = "Install the browser bridge first."
      return
    }
    NSWorkspace.shared.open(directory)
  }

  func openBrowserExtensionManager() {
    let browsers = [
      ("app.zen-browser.zen", "about:debugging#/runtime/this-firefox"),
      ("org.mozilla.firefox", "about:debugging#/runtime/this-firefox"),
      ("com.google.Chrome", "chrome://extensions"),
      ("com.microsoft.edgemac", "edge://extensions"),
      ("com.brave.Browser", "brave://extensions"),
      ("org.chromium.Chromium", "chrome://extensions"),
    ]
    guard
      let browser = browsers.first(where: {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil
      })
    else {
      browserOperationMessage =
        "Use Zen, Firefox, Chrome, Edge, Brave, or Chromium to load the extension. Safari is not supported yet."
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", browser.0, browser.1]
    do {
      try process.run()
    } catch {
      browserOperationMessage =
        "Could not open the browser extension manager: \(error.localizedDescription)"
    }
  }

  func openDataFolder() {
    NSWorkspace.shared.open(AppPaths.applicationSupportDirectory)
  }

  private func runCodexSetup(command: String) {
    guard !isRunningCodexSetup else { return }
    guard let executableURL = Self.notchCLIURL() else {
      operationMessage =
        "notchctl was not found. Build the packaged app before installing hooks."
      return
    }

    isRunningCodexSetup = true
    operationMessage = nil
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.run(executableURL: executableURL, arguments: [command])
      }.value
      guard let self else { return }
      self.isRunningCodexSetup = false
      self.refreshCodexHookStatus()
      self.operationMessage = result.message
    }
  }

  private func runBrowserSetup(command: String) {
    guard !isRunningBrowserSetup else { return }
    guard let executableURL = Self.notchCLIURL() else {
      browserOperationMessage =
        "notchctl was not found. Build the packaged app before installing the browser bridge."
      return
    }

    isRunningBrowserSetup = true
    browserOperationMessage = nil
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.run(executableURL: executableURL, arguments: [command])
      }.value
      guard let self else { return }
      self.isRunningBrowserSetup = false
      self.refreshBrowserExtensionStatus()
      self.browserOperationMessage = result.message
    }
  }

  private func refreshCodexHookStatus() {
    codexHooksInstalled = Self.codexHooksAreInstalled()
    let installed = codexHooksInstalled
    codexHelperCheck &+= 1
    let check = codexHelperCheck
    Task { [weak self] in
      let stale = await Task.detached(priority: .utility) {
        installed && Self.helperIsStale(
          installed: Self.installedHelperURL("notchctl"),
          bundled: Self.notchCLIURL()
        )
      }.value
      guard let self, check == self.codexHelperCheck else { return }
      self.codexHooksNeedUpdate = stale
    }
  }

  private func refreshBrowserExtensionStatus() {
    browserExtensionInstalled = Self.browserExtensionIsInstalled()
    let installed = browserExtensionInstalled
    browserHelperCheck &+= 1
    let check = browserHelperCheck
    Task { [weak self] in
      let stale = await Task.detached(priority: .utility) {
        installed && Self.helperIsStale(
          installed: Self.installedHelperURL("notchrouter-browser-host"),
          bundled: Self.notchCLIURL()?.deletingLastPathComponent()
            .appendingPathComponent("notchrouter-browser-host")
        )
      }.value
      guard let self, check == self.browserHelperCheck else { return }
      self.browserBridgeNeedsUpdate = stale
    }
  }

  nonisolated private static func installedHelperURL(_ name: String) -> URL {
    AppPaths.applicationSupportDirectory
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent(name)
  }

  /// An installed helper is stale when it differs from the copy bundled with
  /// the running app. Without a bundled copy to compare against, assume it is
  /// current rather than nag.
  nonisolated static func helperIsStale(installed: URL, bundled: URL?) -> Bool {
    guard let bundled, FileManager.default.isReadableFile(atPath: bundled.path) else {
      return false
    }
    guard
      let installedData = try? Data(contentsOf: installed, options: .mappedIfSafe),
      let bundledData = try? Data(contentsOf: bundled, options: .mappedIfSafe)
    else { return true }
    return installedData != bundledData
  }

  nonisolated private static func notchCLIURL() -> URL? {
    var candidates: [URL] = []
    if let resourceURL = Bundle.main.resourceURL {
      candidates.append(
        resourceURL.appendingPathComponent("bin/notchctl")
      )
    }
    if let executableURL = Bundle.main.executableURL {
      candidates.append(
        executableURL.deletingLastPathComponent()
          .appendingPathComponent("notchctl")
      )
    }
    return candidates.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
  }

  nonisolated static func run(
    executableURL: URL,
    arguments: [String]
  ) -> CommandResult {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      let outputBuffer = CommandOutputBuffer()
      let errorBuffer = CommandOutputBuffer()
      let drainGroup = DispatchGroup()
      drain(outputPipe, into: outputBuffer, group: drainGroup)
      drain(errorPipe, into: errorBuffer, group: drainGroup)
      try process.run()
      process.waitUntilExit()
      drainGroup.wait()
      let output = String(
        data: outputBuffer.data,
        encoding: .utf8
      )?.trimmingCharacters(in: .whitespacesAndNewlines)
      let error = String(
        data: errorBuffer.data,
        encoding: .utf8
      )?.trimmingCharacters(in: .whitespacesAndNewlines)
      if process.terminationStatus == 0 {
        return CommandResult(message: output?.isEmpty == false ? output! : "Done.")
      }
      return CommandResult(
        message: error?.isEmpty == false
          ? error!
          : "notchctl exited with status \(process.terminationStatus)."
      )
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      return CommandResult(message: error.localizedDescription)
    }
  }

  nonisolated private static func drain(
    _ pipe: Pipe,
    into buffer: CommandOutputBuffer,
    group: DispatchGroup
  ) {
    group.enter()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        if buffer.finish() {
          group.leave()
        }
        return
      }
      buffer.append(data)
    }
  }

  nonisolated private static func codexHooksAreInstalled() -> Bool {
    let hooksURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("hooks.json")
    guard
      let data = try? Data(contentsOf: hooksURL),
      let text = String(data: data, encoding: .utf8)
    else { return false }
    return text.contains("notchctl") && text.contains("codex-hook")
  }

  nonisolated private static func browserExtensionIsInstalled() -> Bool {
    let supportDirectory = AppPaths.applicationSupportDirectory
    let hostURL =
      supportDirectory
      .appendingPathComponent("bin/notchrouter-browser-host")
    let extensionManifestURL =
      supportDirectory
      .appendingPathComponent("browser-extension/manifest.json")
    let library = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    let manifestDirectories = BrowserBridgeConfiguration.manifestDirectories
    return FileManager.default.isExecutableFile(atPath: hostURL.path)
      && FileManager.default.fileExists(atPath: extensionManifestURL.path)
      && manifestDirectories.allSatisfy {
        FileManager.default.fileExists(
          atPath: library.appendingPathComponent(
            "\($0)/com.notchrouter.browser_media.json"
          ).path
        )
      }
  }
}

struct CommandResult: Sendable {
  let message: String
}

private final class CommandOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()
  private var isFinished = false

  var data: Data {
    lock.withLock { storage }
  }

  func append(_ data: Data) {
    lock.withLock {
      storage.append(data)
    }
  }

  func finish() -> Bool {
    lock.withLock {
      guard !isFinished else { return false }
      isFinished = true
      return true
    }
  }
}

struct SettingsDependencies {
  let launchAtLogin: LaunchAtLoginController
  let displaySelection: DisplaySelectionController
  let activityStore: ActivityStore
  let systemMonitor: SystemMonitorController
  let clipboard: ClipboardStore
  let music: MusicController
  let notifications: ActivityNotificationService
  let server: ActivityHTTPServer
  let integrations: IntegrationSettingsController
}
