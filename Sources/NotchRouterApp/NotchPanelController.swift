import AppKit
import SwiftUI

@MainActor
final class NotchPanelController {
  let viewModel = NotchViewModel()

  private let panel: NotchPanel
  private let store: ActivityStore
  private let fileShelf: FileShelfStore
  private let downloads: BrowserDownloadStore
  private let battery: BatteryMonitor
  private let clipboard: ClipboardStore
  private let music: MusicController
  private let focusTimer: FocusTimerController
  private let notificationService: ActivityNotificationService
  private let server: ActivityHTTPServer
  private let systemMonitor: SystemMonitorController
  private let displaySelection: DisplaySelectionController
  nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
  nonisolated(unsafe) private var outsideClickMonitor: Any?
  nonisolated(unsafe) private var localClickMonitor: Any?
  nonisolated(unsafe) private var dynamicDisplayTrackingTimer: Timer?
  private var lastResolvedScreenIdentifier: CGDirectDisplayID?
  private var lastResolvedMode: SurfaceMode?
  private var previouslyActiveApplication: NSRunningApplication?
  private var isPanelSuppressed = false
  private var surfaceTransitionID = 0
  private var isSurfaceTransitioning = false

  init(
    store: ActivityStore,
    fileShelf: FileShelfStore,
    downloads: BrowserDownloadStore,
    battery: BatteryMonitor,
    clipboard: ClipboardStore,
    music: MusicController,
    focusTimer: FocusTimerController,
    notificationService: ActivityNotificationService,
    server: ActivityHTTPServer,
    systemMonitor: SystemMonitorController,
    displaySelection: DisplaySelectionController,
    onOpenSettings: @escaping () -> Void
  ) {
    self.store = store
    self.fileShelf = fileShelf
    self.downloads = downloads
    self.battery = battery
    self.clipboard = clipboard
    self.music = music
    self.focusTimer = focusTimer
    self.notificationService = notificationService
    self.server = server
    self.systemMonitor = systemMonitor
    self.displaySelection = displaySelection
    panel = NotchPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    configurePanel()
    let rootView = NotchRootView(
      store: store,
      fileShelf: fileShelf,
      downloads: downloads,
      battery: battery,
      clipboard: clipboard,
      music: music,
      focusTimer: focusTimer,
      server: server,
      systemMonitor: systemMonitor,
      viewModel: viewModel,
      onOpenSettings: onOpenSettings
    )
    panel.contentView = NSHostingView(rootView: rootView)
    panel.initialFirstResponder = panel.contentView
    panel.onKeyDown = { [weak self] event in
      self?.handleKeyDown(event) ?? false
    }

    viewModel.onModeChange = { [weak self] mode in
      guard let self else { return }
      self.updateFrame(for: mode, animated: true)
      if mode == .compact {
        if self.panel.isKeyWindow {
          self.panel.resignKey()
          if let previouslyActiveApplication = self.previouslyActiveApplication,
            NSApp.isActive
          {
            NSApp.yieldActivation(to: previouslyActiveApplication)
          } else if NSApp.isActive {
            NSApp.deactivate()
          }
        }
        self.previouslyActiveApplication = nil
      }
    }
    viewModel.onSectionChange = { [weak self] in
      self?.updateSystemMonitoring()
    }
    viewModel.onPresentationChange = { [weak self] in
      guard let self else { return }
      self.updateFrame(for: self.viewModel.mode, animated: true)
    }
    store.onIngest = { [weak self] activity in
      self?.viewModel.activityArrived(activity)
    }
    music.onChange = { [weak self] event in
      guard let self else { return }
      self.viewModel.musicChanged(
        event: event,
        hasActiveActivity: self.store.activeActivity != nil
      )
      self.updateFrame(for: self.viewModel.mode, animated: true)
    }
    focusTimer.onChange = { [weak self] event in
      guard let self else { return }
      if event == .completed {
        self.viewModel.focusTimerCompleted(
          hasActiveActivity: self.store.activeActivity != nil
        )
        self.notificationService.deliverFocusCompletion(
          durationMinutes: self.focusTimer.selectedDurationMinutes
        )
      }
      self.updateFrame(for: self.viewModel.mode, animated: true)
    }
    downloads.onChange = { [weak self] in
      guard let self else { return }
      self.updateFrame(for: self.viewModel.mode, animated: true)
    }
    battery.onChange = { [weak self] in
      guard let self else { return }
      self.updateFrame(for: self.viewModel.mode, animated: true)
    }

    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.displaySelection.refreshDisplays()
        self?.updateFrame(for: self?.viewModel.mode ?? .compact, animated: false)
      }
    }

    displaySelection.onSelectionChange = { [weak self] in
      self?.updateFrame(for: self?.viewModel.mode ?? .compact, animated: false)
    }

    let dynamicDisplayTrackingTimer = Timer(
      timeInterval: 1,
      repeats: true
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.displaySelection.behavior != .pinned else {
          return
        }
        guard let screen = self.targetScreen() else { return }
        let mode = self.viewModel.mode
        guard self.displayID(for: screen) != self.lastResolvedScreenIdentifier
          || mode != self.lastResolvedMode
        else { return }
        self.updateFrame(for: mode, animated: true)
      }
    }
    dynamicDisplayTrackingTimer.tolerance = 0.25
    RunLoop.main.add(dynamicDisplayTrackingTimer, forMode: .common)
    self.dynamicDisplayTrackingTimer = dynamicDisplayTrackingTimer

    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.viewModel.mode == .expanded else { return }
        if !self.surfaceFrame.contains(NSEvent.mouseLocation) {
          self.viewModel.collapse()
        }
      }
    }

    localClickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .leftMouseDown
    ) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, event.window === self.panel else { return }
        self.focusPanel()
      }
      return event
    }

    updateFrame(for: .compact, animated: false)
    if !isPanelSuppressed {
      panel.orderFrontRegardless()
    }
  }

  deinit {
    dynamicDisplayTrackingTimer?.invalidate()
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
    if let outsideClickMonitor {
      NSEvent.removeMonitor(outsideClickMonitor)
    }
    if let localClickMonitor {
      NSEvent.removeMonitor(localClickMonitor)
    }
  }

  func show(_ section: NotchSection = .activity) {
    viewModel.show(section)
    focusPanel()
  }

  func refreshLayout() {
    updateFrame(for: viewModel.mode, animated: true)
  }

  private func configurePanel() {
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.level = NSWindow.Level(
      rawValue: NSWindow.Level.statusBar.rawValue + 8
    )
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .stationary,
      .fullScreenAuxiliary,
      .ignoresCycle,
    ]
    panel.animationBehavior = .none
    panel.acceptsMouseMovedEvents = true
    panel.autorecalculatesKeyViewLoop = true
  }

  private func focusPanel() {
    guard !isPanelSuppressed else { return }
    if !NSApp.isActive,
      let frontmostApplication = NSWorkspace.shared.frontmostApplication,
      frontmostApplication.processIdentifier
        != NSRunningApplication.current.processIdentifier
    {
      previouslyActiveApplication = frontmostApplication
    }
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.panel.isKeyWindow else { return }
      self.panel.recalculateKeyViewLoop()
      if self.panel.firstResponder == nil {
        self.panel.makeFirstResponder(self.panel.contentView)
      }
    }
  }

  private func handleKeyDown(_ event: NSEvent) -> Bool {
    guard
      let action = PanelKeyboardAction.resolve(
        keyCode: event.keyCode,
        modifierFlags: event.modifierFlags
      )
    else { return false }

    switch action {
    case .selectNextKeyView, .selectPreviousKeyView:
      // Let SwiftUI move focus, including out of a text field's field editor.
      return false
    case .collapse:
      viewModel.collapse()
      return true
    case .selectPreviousSection:
      return viewModel.selectAdjacentSection(offset: -1)
    case .selectNextSection:
      return viewModel.selectAdjacentSection(offset: 1)
    case .selectSection(let number):
      return viewModel.selectSection(keyboardNumber: number)
    }
  }

  private func updateSystemMonitoring() {
    systemMonitor.setPresentation(
      mode: viewModel.mode, section: viewModel.selectedSection,
      isVisible: !isPanelSuppressed
    )
  }

  private func updateFrame(for mode: SurfaceMode, animated: Bool) {
    defer { updateSystemMonitoring() }
    guard let screen = targetScreen() else { return }
    let screenChanged = displayID(for: screen) != lastResolvedScreenIdentifier
    lastResolvedScreenIdentifier = displayID(for: screen)
    lastResolvedMode = mode
    let geometry = NotchGeometry(screen: screen)

    viewModel.hardwareNotchWidth = geometry.hardwareWidth
    viewModel.hardwareNotchHeight = geometry.hardwareHeight
    viewModel.hasPhysicalNotch = geometry.hasPhysicalNotch

    if displaySelection.hidesOnExternalDisplays,
      !geometry.hasPhysicalNotch,
      !isBuiltInDisplay(screen)
    {
      isPanelSuppressed = true
      panel.orderOut(nil)
      return
    }
    let wasPanelSuppressed = isPanelSuppressed
    isPanelSuppressed = false

    var presentation = viewModel.presentation
    presentation.update(
      available: [
        store.activeActivity != nil ? .agent : nil,
        downloads.activeDownload != nil ? .download : nil,
        focusTimer.isPresented ? .focus : nil,
        music.nowPlaying != nil ? .music : nil,
        battery.charging != nil ? .battery : nil,
      ].compactMap { $0 },
      needsApproval: store.activeActivity?.state == .needsApproval
    )
    if presentation != viewModel.presentation {
      viewModel.presentation = presentation
    }
    let size = geometry.surfaceSize(
      for: mode,
      presentation: presentation,
      hasRecentActivity: store.currentActivity != nil
    )
    let restingSize = NotchGeometry.restingPanelSize(surface: size, mode: mode)
    let restingFrame = panelFrame(size: restingSize, on: screen)
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    defer {
      if wasPanelSuppressed {
        panel.orderFrontRegardless()
      }
    }

    guard animated, !reduceMotion, !screenChanged, viewModel.surfaceSize != .zero else {
      surfaceTransitionID &+= 1
      isSurfaceTransitioning = false
      viewModel.surfaceSize = size
      if !NSEqualRects(panel.frame, restingFrame) {
        panel.setFrame(restingFrame, display: true)
      }
      return
    }

    // Activity, download, and battery updates call this often; leave an
    // in-flight or settled transition to the same size alone.
    if size == viewModel.surfaceSize,
      isSurfaceTransitioning || NSEqualRects(panel.frame, restingFrame)
    {
      return
    }

    // Grow the panel first so it holds the old outline, the new one, and the
    // spring's overshoot. SwiftUI then animates the outline inside it, and the
    // panel shrinks to the resting frame once the spring settles so the
    // transparent margin never covers menu bar items.
    let canvas = NotchGeometry.transitionCanvasSize(
      displayed: panel.frame.size,
      target: restingSize
    )
    surfaceTransitionID &+= 1
    let transitionID = surfaceTransitionID
    isSurfaceTransitioning = true
    panel.setFrame(panelFrame(size: canvas, on: screen), display: true)
    withAnimation(NotchMotion.surface, completionCriteria: .removed) {
      viewModel.surfaceSize = size
    } completion: { [weak self] in
      guard let self, transitionID == self.surfaceTransitionID else { return }
      self.isSurfaceTransitioning = false
      self.panel.setFrame(restingFrame, display: true)
    }
  }

  /// The visible surface in screen coordinates. The panel can be larger, for
  /// the dashboard's shadow or while a transition is running.
  private var surfaceFrame: NSRect {
    let size = viewModel.surfaceSize
    return NSRect(
      x: panel.frame.midX - size.width / 2,
      y: panel.frame.maxY - size.height,
      width: size.width,
      height: size.height
    )
  }

  private func panelFrame(size: CGSize, on screen: NSScreen) -> NSRect {
    NSRect(
      x: screen.frame.midX - size.width / 2,
      y: screen.frame.maxY - size.height,
      width: size.width,
      height: size.height
    )
  }

  private func screenContainingPointer() -> NSScreen? {
    let point = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(point) }
  }

  private func targetScreen() -> NSScreen? {
    switch displaySelection.behavior {
    case .pointer:
      screenContainingPointer()
        ?? panel.screen
        ?? NSScreen.main
        ?? NSScreen.screens.first
    case .activeWindow:
      screenContainingActiveWindow()
        ?? panel.screen
        ?? NSScreen.main
        ?? NSScreen.screens.first
    case .pinned:
      displaySelection.selectedScreen()
        ?? NSScreen.main
        ?? NSScreen.screens.first
    }
  }

  private func screenContainingActiveWindow() -> NSScreen? {
    guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
      return nil
    }

    if frontmostApplication.processIdentifier
      == NSRunningApplication.current.processIdentifier
    {
      return NSApp.keyWindow?.screen ?? panel.screen
    }

    guard
      let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else { return nil }

    for window in windowList {
      guard
        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
          == frontmostApplication.processIdentifier,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(
          dictionaryRepresentation: boundsDictionary as CFDictionary
        ),
        bounds.width > 1,
        bounds.height > 1
      else { continue }

      if let screen = screen(containingMostOf: bounds) {
        return screen
      }
    }
    return nil
  }

  private func screen(containingMostOf windowBounds: CGRect) -> NSScreen? {
    NSScreen.screens.max { first, second in
      intersectionArea(windowBounds, displayBounds(for: first))
        < intersectionArea(windowBounds, displayBounds(for: second))
    }.flatMap { screen in
      intersectionArea(windowBounds, displayBounds(for: screen)) > 0
        ? screen
        : nil
    }
  }

  private func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
    let intersection = first.intersection(second)
    guard !intersection.isNull else { return 0 }
    return intersection.width * intersection.height
  }

  private func displayBounds(for screen: NSScreen) -> CGRect {
    guard let displayID = displayID(for: screen) else { return .null }
    return CGDisplayBounds(displayID)
  }

  private func isBuiltInDisplay(_ screen: NSScreen) -> Bool {
    guard let displayID = displayID(for: screen) else { return true }
    return CGDisplayIsBuiltin(displayID) != 0
  }

  private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
  }
}

private final class NotchPanel: NSPanel {
  var onKeyDown: ((NSEvent) -> Bool)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, onKeyDown?(event) == true {
      return
    }
    super.sendEvent(event)
  }
}

enum PanelKeyboardAction: Equatable {
  case selectNextKeyView
  case selectPreviousKeyView
  case collapse
  case selectPreviousSection
  case selectNextSection
  case selectSection(Int)

  static func resolve(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags
  ) -> PanelKeyboardAction? {
    let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
    let commandModifiers = modifiers.subtracting([
      .capsLock,
      .function,
      .numericPad,
    ])

    if keyCode == 48 {
      if commandModifiers.isEmpty {
        return .selectNextKeyView
      }
      if commandModifiers == .shift {
        return .selectPreviousKeyView
      }
      return nil
    }

    guard commandModifiers.isEmpty else { return nil }

    return switch keyCode {
    case 53: .collapse
    case 123: .selectPreviousSection
    case 124: .selectNextSection
    case 18, 83: .selectSection(1)
    case 19, 84: .selectSection(2)
    case 20, 85: .selectSection(3)
    case 21, 86: .selectSection(4)
    case 23, 87: .selectSection(5)
    case 22, 88: .selectSection(6)
    default: nil
    }
  }
}

struct NotchGeometry {
  let hasPhysicalNotch: Bool
  let hardwareWidth: CGFloat
  let hardwareHeight: CGFloat
  let menuBarHeight: CGFloat

  init(screen: NSScreen) {
    self.init(
      screenWidth: screen.frame.width,
      safeAreaTop: screen.safeAreaInsets.top,
      menuBarHeight: max(screen.safeAreaInsets.top, NSStatusBar.system.thickness),
      auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
      auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width
    )
  }

  init(
    screenWidth: CGFloat,
    safeAreaTop: CGFloat,
    menuBarHeight: CGFloat = 24,
    auxiliaryTopLeftWidth: CGFloat?,
    auxiliaryTopRightWidth: CGFloat?
  ) {
    self.menuBarHeight = max(safeAreaTop, menuBarHeight)
    guard
      let auxiliaryTopLeftWidth,
      let auxiliaryTopRightWidth,
      safeAreaTop > 0
    else {
      hasPhysicalNotch = false
      hardwareWidth = 0
      hardwareHeight = 0
      return
    }

    let width = screenWidth - auxiliaryTopLeftWidth - auxiliaryTopRightWidth
    guard width > 40 else {
      hasPhysicalNotch = false
      hardwareWidth = 0
      hardwareHeight = 0
      return
    }

    hasPhysicalNotch = true
    hardwareWidth = width
    hardwareHeight = safeAreaTop
  }

  func compactSize(
    primary: CompactActivityKind?,
    hasRecentActivity: Bool,
    showsIndicator: Bool
  ) -> CGSize {
    let active = primary != nil || hasRecentActivity
    let wings: CGFloat = !active ? 0 : (primary == .music && !showsIndicator ? 80 : 220)
    return CGSize(width: restingWidth + wings, height: menuBarHeight)
  }

  /// Full surface size for a mode, including the ears on both sides.
  func surfaceSize(
    for mode: SurfaceMode,
    presentation: CompactPresentation,
    hasRecentActivity: Bool
  ) -> CGSize {
    var size: CGSize
    switch mode {
    case .compact:
      size = compactSize(
        primary: presentation.primary,
        hasRecentActivity: hasRecentActivity,
        showsIndicator: presentation.showsIndicator
      )
    case .peek where presentation.primary == .music:
      size = CGSize(
        width: hasPhysicalNotch ? max(restingWidth + 238, 438) : 400,
        height: hasPhysicalNotch ? max(restingHeight + 126, 158) : 136
      )
    case .peek:
      size = CGSize(
        width: max(restingWidth + 208, 408),
        height: max(restingHeight + 52, 90)
      )
    case .expanded:
      size = CGSize(width: 560, height: 500)
    }

    if mode == .peek, presentation.showsIndicator {
      size.height += 28
    }
    size.width += 2 * NotchSurfaceMetrics(mode: mode).earRadius
    return size
  }

  /// Panel size once the surface settles. Only the expanded dashboard casts a
  /// shadow, so compact and peek panels stay flush with the surface and never
  /// cover menu bar items beside it.
  static func restingPanelSize(surface: CGSize, mode: SurfaceMode) -> CGSize {
    guard mode == .expanded else { return surface }
    return CGSize(width: surface.width + 2 * 20, height: surface.height + 30)
  }

  /// Panel size while the surface animates from `displayed` to `target`.
  /// The extra room keeps the spring's overshoot from being clipped.
  static func transitionCanvasSize(displayed: CGSize, target: CGSize) -> CGSize {
    let overshootMargin: CGFloat = 16
    return CGSize(
      width: max(displayed.width, target.width + 2 * overshootMargin),
      height: max(displayed.height, target.height + overshootMargin)
    )
  }

  var restingWidth: CGFloat {
    hasPhysicalNotch ? max(hardwareWidth, 176) : 176
  }

  var restingHeight: CGFloat {
    menuBarHeight
  }
}
