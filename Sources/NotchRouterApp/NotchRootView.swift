import AppKit
import SwiftUI

struct NotchRootView: View {
  let store: ActivityStore
  let fileShelf: FileShelfStore
  let downloads: BrowserDownloadStore
  let battery: BatteryMonitor
  let clipboard: ClipboardStore
  let music: MusicController
  let focusTimer: FocusTimerController
  let server: ActivityHTTPServer
  let systemMonitor: SystemMonitorController
  let viewModel: NotchViewModel
  let onOpenSettings: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var artworkNamespace

  private var metrics: NotchSurfaceMetrics {
    NotchSurfaceMetrics(mode: viewModel.mode)
  }

  // The panel can be larger than the surface (mid-transition, or to make room
  // for the dashboard's shadow), so the surface keeps its own size, pinned to
  // the top center of the panel.
  var body: some View {
    ZStack(alignment: .top) {
      if viewModel.mode == .expanded {
        // Clicks in the shadow margin count as outside the notch.
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { viewModel.collapse() }
      }

      // Drawn from the outline alone, outside the surface's clip, so the
      // shadow does not re-render the dashboard content every frame.
      NotchSurfaceShape(metrics)
        .fill(.black)
        .shadow(
          color: .black.opacity(viewModel.mode == .expanded ? 0.5 : 0),
          radius: 16,
          y: 8
        )
        .frame(width: viewModel.surfaceSize.width, height: viewModel.surfaceSize.height)
        .allowsHitTesting(false)
        .animation(
          reduceMotion ? NotchMotion.reduced : NotchMotion.surface,
          value: viewModel.mode
        )

      surface
        .frame(width: viewModel.surfaceSize.width, height: viewModel.surfaceSize.height)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onChange(of: viewModel.isFileDropTargeted) { _, isTargeted in
      if isTargeted {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
      }
    }
  }

  private var surface: some View {
    ZStack(alignment: .top) {
      NotchSurfaceShape(metrics)
        .fill(.black)

      if music.nowPlaying != nil, let palette = music.artworkPalette {
        MusicAmbientGlow(palette: palette, metrics: metrics)
          .allowsHitTesting(false)
          .transition(.opacity)
      }

      content
        .padding(.horizontal, metrics.earRadius)
        .transition(
          reduceMotion ? AnyTransition.opacity : AnyTransition(NotchMorphTransition())
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .clipShape(NotchSurfaceShape(metrics))
    .contentShape(NotchSurfaceShape(metrics))
    .onHover { viewModel.pointerChanged(isInside: $0) }
    .onTapGesture {
      if viewModel.mode != .expanded {
        viewModel.toggleExpanded()
      }
    }
    .animation(
      reduceMotion ? NotchMotion.reduced : NotchMotion.surface,
      value: viewModel.mode
    )
    .animation(
      reduceMotion ? .linear(duration: 0.15) : .snappy(duration: 0.45),
      value: music.artworkPalette
    )
    .onChange(of: availableActivities) { _, _ in
      viewModel.onPresentationChange?()
    }
    .onChange(of: store.activeActivity?.state == .needsApproval) { _, _ in
      viewModel.onPresentationChange?()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("NotchRouter")
    .contextMenu {
      ForEach(availableActivities) { kind in
        Button("Pin \(kind.title) for 5 minutes", systemImage: kind.symbolName) {
          viewModel.pinActivity(kind)
        }
      }
      if viewModel.presentation.pinned != nil {
        Button("Unpin activity", systemImage: "pin.slash") {
          viewModel.unpinActivity()
        }
      }
      Divider()
      Button("Settings…", systemImage: "gearshape", action: onOpenSettings)
      Button {
        NSApp.terminate(nil)
      } label: {
        Label("Quit NotchRouter", systemImage: "power")
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      if !urls.isEmpty {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      }
      Task { await fileShelf.add(urls) }
      viewModel.show(.files)
      viewModel.prepareForFileDrop(isTargeted: false)
      return !urls.isEmpty
    } isTargeted: { isTargeted in
      viewModel.prepareForFileDrop(isTargeted: isTargeted)
    }
    .environment(\.artworkMorphNamespace, reduceMotion ? nil : artworkNamespace)
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.mode {
    case .compact:
      menuBarContent
    case .peek:
      compactContent(isPeek: true)
    case .expanded:
      ExpandedDashboardView(
        store: store,
        fileShelf: fileShelf,
        downloads: downloads,
        clipboard: clipboard,
        music: music,
        focusTimer: focusTimer,
        server: server,
        systemMonitor: systemMonitor,
        battery: battery,
        viewModel: viewModel,
        onOpenSettings: onOpenSettings
      )
    }
  }

  private var availableActivities: [CompactActivityKind] {
    [
      store.activeActivity != nil ? .agent : nil,
      downloads.activeDownload != nil ? .download : nil,
      focusTimer.isPresented ? .focus : nil,
      music.nowPlaying != nil ? .music : nil,
      battery.charging != nil ? .battery : nil,
    ].compactMap { $0 }
  }

  // A single row for every passive state. The physical cutout keeps equal
  // space on both sides, including when secondary activities are visible.
  private var menuBarContent: some View {
    HStack(spacing: 6) {
      HStack(spacing: 5) {
        compactGlyph
        if viewModel.presentation.primary != .music || !viewModel.hasPhysicalNotch {
          Text(compactTitle)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if viewModel.hasPhysicalNotch {
        Color.clear.frame(width: viewModel.hardwareNotchWidth)
      }

      HStack(spacing: 5) {
        if viewModel.presentation.primary == .music {
          PlaybackIndicator(
            isPlaying: music.nowPlaying?.isPlaying == true,
            tint: music.artworkPalette?.accent ?? .pink
          )
        } else {
          Text(compactStatus).lineLimit(1).monospacedDigit()
            .rollingNumber(compactStatus, countsDown: viewModel.presentation.primary == .focus)
        }
        if viewModel.presentation.showsIndicator {
          // Full pin controls remain available in the user-opened preview.
          Image(systemName: viewModel.presentation.secondary.first?.symbolName ?? "pin.fill")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Other active features. Hover or click for details")
          if viewModel.presentation.secondary.count > 1 {
            Text("+\(viewModel.presentation.secondary.count - 1)")
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .font(.caption2.weight(.semibold))
    .padding(.horizontal, 9)
    .frame(maxHeight: .infinity)
  }

  @ViewBuilder
  private var compactGlyph: some View {
    if viewModel.presentation.primary == .music, let snapshot = music.nowPlaying {
      MusicArtworkView(snapshot: snapshot, size: 18, cornerRadius: 4)
    } else if viewModel.presentation.primary == .agent, let activity = store.activeActivity {
      ActivityStatusGlyph(state: activity.state, size: 16)
    } else {
      Image(systemName: viewModel.presentation.primary?.symbolName ?? "sparkles")
    }
  }

  private var compactTitle: String {
    switch viewModel.presentation.primary {
    case .agent: store.activeActivity?.source ?? "Agent"
    case .download: downloads.activeDownload?.displayName ?? "Download"
    case .focus: "Focus"
    case .music: music.nowPlaying?.title ?? "Music"
    case .battery: "Charging"
    case nil: store.currentActivity?.source ?? ""
    }
  }

  private var compactStatus: String {
    switch viewModel.presentation.primary {
    case .agent:
      let label = store.activeActivity?.state.shortLabel ?? ""
      return store.activeCount > 1 ? "\(label) · \(store.activeCount)" : label
    case .download:
      guard let item = downloads.activeDownload else { return "" }
      return item.isPaused ? "Paused" : item.progress?.formatted(.percent.precision(.fractionLength(0))) ?? "Downloading"
    case .focus: return focusTimer.formattedRemaining
    case .battery: return battery.charging.map { "\($0.level)%" } ?? ""
    case .music: return ""
    case nil: return store.currentActivity?.state.shortLabel ?? ""
    }
  }

  private func compactContent(isPeek: Bool) -> some View {
    VStack(spacing: 0) {
      primaryContent(isPeek: isPeek)
      if viewModel.presentation.showsIndicator {
        HStack(spacing: 8) {
          if let pinned = viewModel.presentation.pinned {
            Button(action: viewModel.unpinActivity) {
              Label(pinned.title, systemImage: "pin.fill")
            }
            .help("Unpin \(pinned.title)")
            .accessibilityLabel("Unpin \(pinned.title)")
          }
          ForEach(viewModel.presentation.secondary.filter { $0 != viewModel.presentation.pinned }) { kind in
            Button { viewModel.pinActivity(kind) } label: {
              Image(systemName: kind.symbolName)
                .frame(minWidth: 24, minHeight: 20)
            }
            .help("Pin \(kind.title) for 5 minutes")
            .accessibilityLabel("\(kind.title) also active. Pin for 5 minutes")
          }
        }
        .font(.caption2)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .padding(.bottom, 4)
      }
    }
  }

  @ViewBuilder
  private func primaryContent(isPeek: Bool) -> some View {
    if viewModel.presentation.primary == .agent, let activity = store.activeActivity {
      CompactActivityView(
        activity: activity,
        activeCount: store.activeCount,
        hardwareNotchWidth: viewModel.hardwareNotchWidth,
        hasPhysicalNotch: viewModel.hasPhysicalNotch,
        isPeek: isPeek,
        currentSection: .activity,
        onSelectSection: viewModel.show
      )
    } else if viewModel.presentation.primary == .download, let download = downloads.activeDownload {
      CompactDownloadView(
        item: download,
        store: downloads,
        hardwareNotchWidth: viewModel.hardwareNotchWidth,
        hasPhysicalNotch: viewModel.hasPhysicalNotch,
        isPeek: isPeek,
        onSelectSection: viewModel.show
      )
    } else if viewModel.presentation.primary == .focus {
      CompactFocusTimerView(
        timer: focusTimer,
        hardwareNotchWidth: viewModel.hardwareNotchWidth,
        hasPhysicalNotch: viewModel.hasPhysicalNotch,
        isPeek: isPeek,
        onSelectSection: viewModel.show
      )
    } else if viewModel.presentation.primary == .music, let snapshot = music.nowPlaying {
      CompactMusicView(
        snapshot: snapshot,
        controller: music,
        hardwareNotchWidth: viewModel.hardwareNotchWidth,
        hardwareNotchHeight: viewModel.hardwareNotchHeight,
        hasPhysicalNotch: viewModel.hasPhysicalNotch,
        isPeek: isPeek,
        onSelectSection: viewModel.show
      )
    } else if viewModel.presentation.primary == .battery, let charging = battery.charging {
      CompactBatteryView(
        charging: charging,
        hardwareNotchWidth: viewModel.hardwareNotchWidth,
        hasPhysicalNotch: viewModel.hasPhysicalNotch,
        isPeek: isPeek,
        onSelectSection: viewModel.show
      )
    } else {
      CompactActivityView(
        activity: store.currentActivity,
        activeCount: store.activeCount,
        hardwareNotchWidth: viewModel.hardwareNotchWidth,
        hasPhysicalNotch: viewModel.hasPhysicalNotch,
        isPeek: isPeek,
        currentSection: store.currentActivity == nil ? nil : .activity,
        onSelectSection: viewModel.show
      )
    }
  }
}
