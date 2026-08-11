import AppKit
import SwiftUI

struct NotchRootView: View {
  @ObservedObject var store: ActivityStore
  @ObservedObject var fileShelf: FileShelfStore
  @ObservedObject var clipboard: ClipboardStore
  @ObservedObject var music: MusicController
  @ObservedObject var focusTimer: FocusTimerController
  @ObservedObject var server: ActivityHTTPServer
  @ObservedObject var viewModel: NotchViewModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .top) {
      NotchSurfaceShape()
        .fill(.black)

      content
        .transition(
          reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
        )
    }
    .contentShape(NotchSurfaceShape())
    .onHover { viewModel.pointerChanged(isInside: $0) }
    .onTapGesture {
      if viewModel.mode != .expanded {
        viewModel.toggleExpanded()
      }
    }
    .animation(
      reduceMotion ? .linear(duration: 0.1) : .snappy(duration: 0.22),
      value: viewModel.mode
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("NotchRouter")
    .contextMenu {
      Button {
        NSApp.terminate(nil)
      } label: {
        Label("Quit NotchRouter", systemImage: "power")
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      fileShelf.add(urls)
      viewModel.show(.files)
      viewModel.prepareForFileDrop(isTargeted: false)
      return !urls.isEmpty
    } isTargeted: { isTargeted in
      viewModel.prepareForFileDrop(isTargeted: isTargeted)
    }
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.mode {
    case .compact:
      compactContent(isPeek: false)
    case .peek:
      compactContent(isPeek: true)
    case .expanded:
      ExpandedDashboardView(
        store: store,
        fileShelf: fileShelf,
        clipboard: clipboard,
        music: music,
        focusTimer: focusTimer,
        server: server,
        viewModel: viewModel
      )
    }
  }

  @ViewBuilder
  private func compactContent(isPeek: Bool) -> some View {
    if let activity = store.activeActivity {
      CompactActivityView(
        activity: activity,
        activeCount: store.activeCount,
        hardwareNotchWidth: viewModel.hardwareNotchWidth,
        hasPhysicalNotch: viewModel.hasPhysicalNotch,
        isPeek: isPeek,
        currentSection: .activity,
        onSelectSection: viewModel.show
      )
    } else if focusTimer.isPresented {
      CompactFocusTimerView(
        timer: focusTimer,
        hardwareNotchWidth: viewModel.hardwareNotchWidth,
        hasPhysicalNotch: viewModel.hasPhysicalNotch,
        isPeek: isPeek,
        onSelectSection: viewModel.show
      )
    } else if let snapshot = music.nowPlaying {
      CompactMusicView(
        snapshot: snapshot,
        controller: music,
        hardwareNotchWidth: viewModel.hardwareNotchWidth,
        hardwareNotchHeight: viewModel.hardwareNotchHeight,
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
