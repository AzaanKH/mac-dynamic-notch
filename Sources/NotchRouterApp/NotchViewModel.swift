import Combine
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
final class NotchViewModel: ObservableObject {
  @Published var mode: SurfaceMode = .compact
  @Published var selectedSection: NotchSection = .activity
  @Published var isFileDropTargeted = false
  @Published var hardwareNotchWidth: CGFloat = 0
  @Published var hardwareNotchHeight: CGFloat = 0
  @Published var hasPhysicalNotch = false

  var onModeChange: ((SurfaceMode) -> Void)?

  private var collapseTask: Task<Void, Never>?
  private var hoverTask: Task<Void, Never>?
  private var isPointerInside = false

  func activityArrived(_ activity: AIActivity) {
    guard mode != .expanded else { return }
    selectedSection = .activity
    setMode(.peek)
    scheduleCollapse(after: activity.state == .needsApproval ? 8 : 4)
  }

  func musicChanged(
    event: MusicPresentationEvent,
    hasActiveActivity: Bool
  ) {
    guard
      event.requestsPeek,
      !hasActiveActivity,
      mode != .expanded
    else { return }
    setMode(.peek)
    scheduleCollapse(after: 3)
  }

  func focusTimerCompleted(hasActiveActivity: Bool) {
    guard !hasActiveActivity, mode != .expanded else { return }
    selectedSection = .focus
    setMode(.peek)
    scheduleCollapse(after: 8)
  }

  func prepareForFileDrop(isTargeted: Bool) {
    isFileDropTargeted = isTargeted
    guard isTargeted else { return }
    selectedSection = .files
    collapseTask?.cancel()
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
    return true
  }

  func pointerChanged(isInside: Bool) {
    isPointerInside = isInside
    if isInside {
      collapseTask?.cancel()
      hoverTask?.cancel()
      if mode == .compact {
        hoverTask = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(110))
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
