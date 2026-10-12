import AppKit
import SwiftUI

struct ExpandedDashboardView: View {
  let store: ActivityStore
  let fileShelf: FileShelfStore
  let downloads: BrowserDownloadStore
  let clipboard: ClipboardStore
  let music: MusicController
  let focusTimer: FocusTimerController
  let server: ActivityHTTPServer
  let systemMonitor: SystemMonitorController
  let battery: BatteryMonitor
  let viewModel: NotchViewModel
  let onOpenSettings: () -> Void
  @FocusState private var focusedSection: NotchSection?
  @Namespace private var sectionSelection
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(spacing: 0) {
      header
      sectionPicker
      if viewModel.hasPhysicalNotch, canClearSection {
        HStack {
          Spacer()
          clearButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
      }

      Group {
        switch viewModel.selectedSection {
        case .activity:
          ActivitySectionView(store: store)
        case .focus:
          FocusTimerSectionView(timer: focusTimer)
        case .files:
          FileShelfSectionView(
            store: fileShelf,
            downloads: downloads,
            isDropTargeted: viewModel.isFileDropTargeted
          )
        case .music:
          MusicSectionView(controller: music)
        case .clipboard:
          ClipboardSectionView(store: clipboard)
        case .system:
          SystemSectionView(monitor: systemMonitor, battery: battery)
        }
      }
      .id(viewModel.selectedSection)
      .transition(
        reduceMotion
          ? AnyTransition.opacity
          : AnyTransition(SectionEntranceTransition(direction: viewModel.sectionDirection))
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      footer
    }
    .padding(.top, 11)
    .animation(
      reduceMotion ? NotchMotion.reduced : NotchMotion.section,
      value: viewModel.selectedSection
    )
    .onChange(of: viewModel.selectedSection) { _, section in
      // Keep keyboard focus with tab navigation without focusing mouse selections.
      if focusedSection != nil {
        focusedSection = section
      }
    }
    .onExitCommand {
      viewModel.collapse()
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("NOTCH ROUTER")
          .font(.caption.weight(.bold))
          .tracking(1.1)
          .dashboardSecondaryText()
        Text(sectionSummary)
          .font(.title3.weight(.semibold))
          .lineLimit(1)
          .sectionSwap(viewModel.selectedSection, reduceMotion: reduceMotion)
      }

      Spacer()

      if canClearSection, !viewModel.hasPhysicalNotch {
        clearButton
      }

      Button(action: onOpenSettings) {
        Image(systemName: "gearshape")
          .font(.callout.weight(.bold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(NotchSubtleButtonStyle())
      .keyboardShortcut(",", modifiers: .command)
      .accessibilityLabel("Open Settings")
      .help("Settings (⌘,)")

      Button {
        viewModel.collapse()
      } label: {
        Image(systemName: "chevron.up")
          .font(.callout.weight(.bold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(NotchSubtleButtonStyle())
      .accessibilityLabel("Collapse notch")
      .help("Collapse notch")

      Button {
        NSApp.terminate(nil)
      } label: {
        Image(systemName: "power")
          .font(.callout.weight(.bold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(NotchSubtleButtonStyle())
      .keyboardShortcut("q", modifiers: .command)
      .accessibilityLabel("Quit NotchRouter")
      .help("Quit NotchRouter (⌘Q)")
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 9)
  }

  private var clearButton: some View {
    Button(action: clearSection) {
      Label(clearLabel, systemImage: "trash")
        .fixedSize()
    }
    .buttonStyle(NotchSubtleButtonStyle(isProminent: true))
  }

  private var sectionPicker: some View {
    HStack(spacing: 5) {
      ForEach(NotchSection.allCases) { section in
        Button {
          if NSApp.currentEvent?.type == .leftMouseUp {
            focusedSection = nil
          }
          viewModel.selectedSection = section
        } label: {
          HStack(spacing: 5) {
            Image(systemName: section.symbolName)
              .font(.caption.weight(.semibold))
            Text(section.title)
              .font(.callout.weight(.semibold))
            if differentiateWithoutColor, viewModel.selectedSection == section {
              Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
            }
          }
          .frame(maxWidth: .infinity)
          .frame(minHeight: 36)
        }
        .buttonStyle(NotchSectionButtonStyle(isSelected: viewModel.selectedSection == section))
        .background {
          if viewModel.selectedSection == section {
            selectionIndicator
          }
        }
        .focused($focusedSection, equals: section)
        .accessibilityAddTraits(
          viewModel.selectedSection == section ? .isSelected : []
        )
        .keyboardShortcut(
          KeyEquivalent(Character(String(section.keyboardNumber))),
          modifiers: []
        )
        .help("\(section.title) (\(section.keyboardNumber))")
      }
    }
    .padding(.horizontal, 13)
    .padding(.bottom, 10)
  }

  // One indicator glides between tabs. With Reduce Motion it only fades.
  @ViewBuilder
  private var selectionIndicator: some View {
    if reduceMotion {
      NotchSectionSelectionIndicator()
    } else {
      NotchSectionSelectionIndicator()
        .matchedGeometryEffect(id: "selectedSection", in: sectionSelection)
    }
  }

  private var footer: some View {
    HStack(spacing: 6) {
      if differentiateWithoutColor {
        Image(systemName: footerSymbolName)
          .font(.caption.weight(.bold))
          .dashboardTint(footerTint)
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
      } else {
        Circle()
          .fill(footerTint)
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
      }
      Text(footerText)
        .font(.caption)
        .dashboardTertiaryText()
        .lineLimit(1)
        .sectionSwap(viewModel.selectedSection, reduceMotion: reduceMotion)
      Spacer()
      if viewModel.selectedSection == .activity, server.state.canRetry {
        Button("Retry API", action: server.start)
          .buttonStyle(NotchSubtleButtonStyle())
          .accessibilityHint("Try to start the local event API again")
      } else {
        Text(footerCount)
          .font(.caption.weight(.medium))
          .dashboardTertiaryText()
          .sectionSwap(viewModel.selectedSection, alignment: .trailing, reduceMotion: reduceMotion)
      }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 38)
    .background(.white.opacity(contrast == .increased ? 0.14 : 0.04))
  }

  private var sectionSummary: String {
    switch viewModel.selectedSection {
    case .activity:
      let activeCount = store.activeCount
      let attentionCount = store.count(in: .attentionRequired)
      if activeCount > 0, attentionCount > 0 {
        return "\(activeCount) active · \(attentionCount) need attention"
      }
      if attentionCount > 0 {
        return attentionCount == 1
          ? "1 activity needs attention"
          : "\(attentionCount) activities need attention"
      }
      if activeCount == 0 {
        return store.activities.isEmpty ? "Nothing active" : "Recent activity"
      }
      return activeCount == 1
        ? "1 activity in progress"
        : "\(activeCount) activities in progress"
    case .focus:
      return focusTimer.phase == .idle
        ? "\(focusTimer.selectedDurationMinutes)-minute focus session"
        : focusTimer.stateLabel
    case .files:
      if downloads.activeCount > 0 {
        return downloads.activeCount == 1
          ? "1 download in progress"
          : "\(downloads.activeCount) downloads in progress"
      }
      return fileShelf.items.isEmpty && downloads.items.isEmpty
        ? "Drop anything here"
        : "Files and downloads"
    case .music:
      return music.nowPlaying?.title ?? "Music controls"
    case .clipboard:
      return clipboard.isEnabled ? "Recent clipboard" : "Clipboard history is off"
    case .system:
      return systemMonitor.isEnabled
        ? "System and network"
        : "System monitoring is off"
    }
  }

  private var canClearSection: Bool {
    switch viewModel.selectedSection {
    case .activity:
      store.activities.contains(where: { $0.state.isTerminal })
    case .focus:
      focusTimer.phase != .idle
    case .files:
      !fileShelf.items.isEmpty || downloads.items.contains(where: { !$0.isActive })
    case .music:
      false
    case .clipboard:
      !clipboard.entries.isEmpty
    case .system:
      false
    }
  }

  private var clearLabel: String {
    switch viewModel.selectedSection {
    case .activity: "Clear finished"
    case .focus: "Reset"
    case .files: "Clear shelf"
    case .clipboard: "Clear history"
    case .music: "Clear"
    case .system: "Clear"
    }
  }

  private func clearSection() {
    switch viewModel.selectedSection {
    case .activity:
      store.clearFinished()
    case .focus:
      focusTimer.reset()
    case .files:
      fileShelf.clear()
      downloads.clearHistory()
    case .clipboard:
      clipboard.clear()
    case .music:
      break
    case .system:
      break
    }
  }

  private var footerTint: Color {
    switch viewModel.selectedSection {
    case .activity:
      switch server.state {
      case .stopped: .gray
      case .starting: .orange
      case .ready: .green
      case .failed: .red
      }
    case .focus: focusTimer.phase == .completed ? .green : .indigo
    case .files: viewModel.isFileDropTargeted ? .orange : .blue
    case .music: music.nowPlaying?.isPlaying == true ? .pink : .gray
    case .clipboard: clipboard.isEnabled ? .purple : .gray
    case .system:
      systemMonitor.isEnabled
        ? (systemMonitor.network.isOnline ? .green : .orange)
        : .gray
    }
  }

  private var footerText: String {
    switch viewModel.selectedSection {
    case .activity:
      switch server.state {
      case .stopped:
        "Private event API stopped"
      case .starting:
        "Starting private event API"
      case .ready:
        "Private event API ready"
      case .failed(let failure):
        failure.isPortConflict
          ? "Local event API unavailable · port \(server.port) is already in use"
          : "Local event API failed · \(failure.message)"
      }
    case .focus: "Local focus timer · continues while the notch is collapsed"
    case .files: "Drag files in or back out · bookmarks stay local"
    case .music: "Apple Music, Spotify, and opt-in browser media"
    case .clipboard: "Local text & image history · sensitive types excluded"
    case .system:
      systemMonitor.isEnabled
        ? "Local metrics only · connection test runs on demand"
        : "Enable in General settings or from this section"
    }
  }

  private var footerSymbolName: String {
    switch viewModel.selectedSection {
    case .activity:
      switch server.state {
      case .stopped: "stop.fill"
      case .starting: "ellipsis"
      case .ready: "checkmark"
      case .failed: "exclamationmark"
      }
    case .focus: focusTimer.phase == .completed ? "checkmark" : "timer"
    case .files: viewModel.isFileDropTargeted ? "arrow.down" : "tray"
    case .music: music.nowPlaying?.isPlaying == true ? "waveform" : "pause.fill"
    case .clipboard: clipboard.isEnabled ? "list.clipboard" : "nosign"
    case .system:
      systemMonitor.isEnabled
        ? (systemMonitor.network.isOnline ? "network" : "wifi.slash")
        : "nosign"
    }
  }

  private var footerCount: String {
    switch viewModel.selectedSection {
    case .activity:
      "\(store.activeCount) active"
    case .focus:
      focusTimer.phase == .idle ? "ready" : focusTimer.formattedRemaining
    case .files:
      "\(fileShelf.items.count) files · \(downloads.items.count) downloads"
    case .music:
      music.isEnabled || music.hasBrowserSession ? "enabled" : "off"
    case .clipboard:
      clipboard.isEnabled ? "\(clipboard.entries.count) clips" : "off"
    case .system:
      systemMonitor.isEnabled ? systemMonitor.network.interfaceName : "off"
    }
  }
}

private extension View {
  /// Swaps section-specific text with a blur, so the old and new strings are
  /// never both sharp while they overlap.
  func sectionSwap(
    _ section: NotchSection,
    alignment: Alignment = .leading,
    reduceMotion: Bool
  ) -> some View {
    ZStack(alignment: alignment) {
      id(section)
        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
    }
  }
}
