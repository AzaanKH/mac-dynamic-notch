import Observation
import Foundation
import NotchRouterCore

enum SurfaceMode: Equatable {
  case compact
  case peek
  case expanded
}

enum NotchSection: String, CaseIterable, Identifiable {
  case activity
  case focus
  case files
  case music
  case clipboard
  case system

  var id: String { rawValue }

  var title: String {
    switch self {
    case .activity: "Activity"
    case .focus: "Focus"
    case .files: "Files"
    case .music: "Music"
    case .clipboard: "Clipboard"
    case .system: "System"
    }
  }

  var symbolName: String {
    switch self {
    case .activity: "sparkles"
    case .focus: "timer"
    case .files: "tray.full"
    case .music: "music.note"
    case .clipboard: "list.clipboard"
    case .system: "gauge.with.dots.needle.33percent"
    }
  }

  var keyboardNumber: Int {
    Self.allCases.firstIndex(of: self)! + 1
  }
}

@MainActor
@Observable
final class NotchViewModel {
  var mode: SurfaceMode = .compact
  var selectedSection: NotchSection = .activity {
    didSet {
      guard selectedSection != oldValue else { return }
      sectionDirection = selectedSection.keyboardNumber > oldValue.keyboardNumber ? 1 : -1
      onSectionChange?()
    }
  }
  /// 1 when the latest section change moved right through the tabs, -1 when
  /// it moved left. Drives the direction of the section entrance.
  private(set) var sectionDirection: CGFloat = 1
  var onSectionChange: (() -> Void)?
  var isFileDropTargeted = false
  var hardwareNotchWidth: CGFloat = 0
  var hardwareNotchHeight: CGFloat = 0
  var hasPhysicalNotch = false
  /// Size of the visible surface, including its ears. The panel controller
  /// animates this; the panel itself may be larger mid-transition.
  var surfaceSize: CGSize = .zero

  var presentation = CompactPresentation()
  var onPresentationChange: (() -> Void)?
  private var pinTask: Task<Void, Never>?

  func pinActivity(_ kind: CompactActivityKind) {
    guard presentation.available.contains(kind) else { return }
    presentation.pin(kind)
    pinTask?.cancel()
    pinTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(300))
      guard !Task.isCancelled else { return }
      self?.unpinActivity()
    }
    onPresentationChange?()
  }

  func unpinActivity() {
    pinTask?.cancel()
    presentation.unpin()
    onPresentationChange?()
  }

  var onModeChange: ((SurfaceMode) -> Void)?

  private var collapseTask: Task<Void, Never>?
  private var hoverTask: Task<Void, Never>?
  private var isPointerInside = false

  func activityArrived(_ activity: AIActivity) {
    // Background events update the compact indicator, never open a preview or
    // replace the section the user is reading.
    if mode == .compact, presentation.pinned == nil || presentation.pinned == .agent {
      selectedSection = .activity
    }
    onPresentationChange?()
  }

  func musicChanged(
    event: MusicPresentationEvent,
    hasActiveActivity: Bool
  ) {
    guard !hasActiveActivity, mode == .compact else { return }
    selectedSection = .music
  }

  func focusTimerCompleted(hasActiveActivity: Bool) {
    guard !hasActiveActivity, mode == .compact else { return }
    selectedSection = .focus
  }

  func prepareForFileDrop(isTargeted: Bool) {
    isFileDropTargeted = isTargeted
    guard isTargeted else { return }
    selectedSection = .files
    collapseTask?.cancel()
    hoverTask?.cancel()
    setMode(.expanded)
  }

  func show(_ section: NotchSection) {
    selectedSection = section
    hoverTask?.cancel()
    collapseTask?.cancel()
    setMode(.expanded)
  }

  @discardableResult
  func selectSection(keyboardNumber: Int) -> Bool {
    guard NotchSection.allCases.indices.contains(keyboardNumber - 1) else {
      return false
    }
    show(NotchSection.allCases[keyboardNumber - 1])
    return true
  }

  @discardableResult
  func selectAdjacentSection(offset: Int) -> Bool {
    guard mode == .expanded, offset != 0 else { return false }
    let sections = NotchSection.allCases
    guard let currentIndex = sections.firstIndex(of: selectedSection) else {
      return false
    }
    let nextIndex = (
      currentIndex + (offset % sections.count) + sections.count
    ) % sections.count
    selectedSection = sections[nextIndex]
    // Wrapping from the last tab to the first still reads as moving right.
    sectionDirection = offset > 0 ? 1 : -1
    return true
  }

  func pointerChanged(isInside: Bool) {
    isPointerInside = isInside
    if isInside {
      collapseTask?.cancel()
      hoverTask?.cancel()
      if mode == .compact {
        hoverTask = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(450))
          guard !Task.isCancelled else { return }
          guard let self, self.isPointerInside, self.mode == .compact else {
            return
          }
          self.setMode(.peek)
        }
      }
    } else {
      hoverTask?.cancel()
      if mode == .peek {
        scheduleCollapse(after: 0.32)
      }
    }
  }

  func expandImmediately() {
    hoverTask?.cancel()
    collapseTask?.cancel()
    setMode(.expanded)
  }

  func toggleExpanded() {
    hoverTask?.cancel()
    collapseTask?.cancel()
    setMode(mode == .expanded ? .compact : .expanded)
  }

  func collapse() {
    guard mode != .compact else { return }
    hoverTask?.cancel()
    collapseTask?.cancel()
    setMode(.compact)
  }

  private func scheduleCollapse(after seconds: Double) {
    collapseTask?.cancel()
    collapseTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.setMode(.compact)
    }
  }

  private func setMode(_ newMode: SurfaceMode) {
    guard mode != newMode else { return }
    mode = newMode
    onModeChange?(newMode)
  }
}
