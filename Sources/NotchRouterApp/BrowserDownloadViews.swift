import NotchRouterCore
import SwiftUI

struct BrowserDownloadHistoryView: View {
  @ObservedObject var store: BrowserDownloadStore

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Label("Downloads", systemImage: "arrow.down.circle")
          .font(.caption.weight(.bold))
          .dashboardSecondaryText()
        if store.activeCount > 0 {
          Text("\(store.activeCount) active")
            .font(.caption2.weight(.bold).monospacedDigit())
            .dashboardTint(.blue)
        }
        Spacer()
        Button("Clear finished") {
          store.clearHistory()
        }
        .buttonStyle(NotchSubtleButtonStyle())
        .focusable()
        .disabled(!store.items.contains(where: { !$0.isActive }))
      }

      ScrollView {
        LazyVStack(spacing: 7) {
          ForEach(store.items) { item in
            BrowserDownloadRow(item: item, store: store)
          }
        }
      }
      .frame(height: min(CGFloat(store.items.count) * 55, 165))
    }
    .padding(10)
    .dashboardSurface(cornerRadius: 13)
  }
}

private struct BrowserDownloadRow: View {
  let item: BrowserDownloadItem
  @ObservedObject var store: BrowserDownloadStore

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: statusSymbol)
        .font(.callout.weight(.semibold))
        .dashboardTint(statusTint)
        .frame(width: 22)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(item.displayName)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          if let sourceHost = item.sourceHost {
            Text("· \(sourceHost)")
              .font(.caption)
              .dashboardTertiaryText()
              .lineLimit(1)
          }
        }
        if item.isActive, let progress = item.progress {
          ProgressView(value: progress)
            .tint(.blue)
        }
        Text(statusText)
          .font(.caption2.monospacedDigit())
          .dashboardSecondaryText()
          .lineLimit(1)
      }

      Spacer(minLength: 4)

      if item.isActive {
        Button {
          item.isPaused ? store.resume(item) : store.pause(item)
        } label: {
          Image(systemName: item.isPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(NotchIconButtonStyle())
        .focusable()
        .accessibilityLabel(item.isPaused ? "Resume \(item.displayName)" : "Pause \(item.displayName)")

        Button {
          store.cancel(item)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(NotchIconButtonStyle())
        .focusable()
        .accessibilityLabel("Cancel \(item.displayName)")
      } else if item.state == .interrupted, item.canResume {
        Button {
          store.resume(item)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(NotchIconButtonStyle())
        .focusable()
        .accessibilityLabel("Resume \(item.displayName)")
      } else if item.state == .complete {
        Button {
          store.reveal(item)
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(NotchIconButtonStyle())
        .focusable()
        .accessibilityLabel("Reveal \(item.displayName)")
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 5)
    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
  }

  private var statusSymbol: String {
    if item.isPaused { return "pause.circle.fill" }
    switch item.state {
    case .inProgress: return "arrow.down.circle.fill"
    case .complete: return "checkmark.circle.fill"
    case .interrupted: return "exclamationmark.circle.fill"
    }
  }

  private var statusTint: Color {
    if item.isPaused { return .orange }
    switch item.state {
    case .inProgress: return .blue
    case .complete: return .green
    case .interrupted: return .orange
    }
  }

  private var statusText: String {
    if item.isPaused { return "Paused · \(byteProgress)" }
    switch item.state {
    case .inProgress:
      if let estimatedEndTime = item.estimatedEndTime {
        let remaining = max(Int(estimatedEndTime.timeIntervalSinceNow.rounded()), 0)
        return "\(byteProgress) · about \(duration(remaining)) left"
      }
      return byteProgress
    case .complete:
      return "Complete · \(bytes(item.bytesReceived)) · \(item.browserName)"
    case .interrupted:
      return item.error.map { "Interrupted · \($0)" } ?? "Interrupted"
    }
  }

  private var byteProgress: String {
    guard item.totalBytes > 0 else { return bytes(item.bytesReceived) }
    return "\(bytes(item.bytesReceived)) of \(bytes(item.totalBytes))"
  }

  private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file)
  }

  private func duration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
  }
}

struct CompactDownloadView: View {
  let item: BrowserDownloadItem
  @ObservedObject var store: BrowserDownloadStore
  let hardwareNotchWidth: CGFloat
  let hasPhysicalNotch: Bool
  let isPeek: Bool
  let onSelectSection: (NotchSection) -> Void

  var body: some View {
    VStack(spacing: 5) {
      if hasPhysicalNotch {
        HStack(spacing: 8) {
          downloadIdentity
            .frame(maxWidth: .infinity, alignment: .leading)
          Color.clear.frame(width: max(hardwareNotchWidth - 20, 120))
          HStack(spacing: 7) {
            progressLabel
            if isPeek {
              pauseResumeButton
            }
          }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      } else {
        HStack(spacing: 9) {
          Image(systemName: item.isPaused ? "pause.circle.fill" : "arrow.down.circle.fill")
            .font(.system(size: isPeek ? 24 : 20))
            .dashboardTint(item.isPaused ? .orange : .blue)
          VStack(alignment: .leading, spacing: 3) {
            Text(item.displayName)
              .font(.callout.weight(.semibold))
              .lineLimit(1)
            if let progress = item.progress {
              ProgressView(value: progress)
                .tint(.blue)
                .frame(maxWidth: 150)
            }
          }
          Spacer(minLength: 8)
          progressLabel
          if isPeek {
            pauseResumeButton
          }
        }
      }

      if isPeek {
        HoverSectionNavigation(currentSection: .files, onSelect: onSelectSection)
      }
    }
    .padding(.horizontal, 11)
    .padding(.top, isPeek ? 5 : 4)
    .padding(.bottom, isPeek ? 7 : 5)
  }

  private var downloadIdentity: some View {
    HStack(spacing: 7) {
      Image(systemName: item.isPaused ? "pause.circle.fill" : "arrow.down.circle.fill")
        .dashboardTint(item.isPaused ? .orange : .blue)
      Text(item.displayName)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
    }
  }

  private var progressLabel: some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(item.progress?.formatted(.percent.precision(.fractionLength(0))) ?? "Downloading")
        .font(.callout.weight(.bold).monospacedDigit())
        .dashboardTint(item.isPaused ? .orange : .blue)
      if isPeek {
        Text(item.isPaused ? "Paused" : "\(bytes(item.bytesReceived)) received")
          .font(.caption)
          .dashboardSecondaryText()
      }
    }
  }

  private var pauseResumeButton: some View {
    Button {
      item.isPaused ? store.resume(item) : store.pause(item)
    } label: {
      Image(systemName: item.isPaused ? "play.fill" : "pause.fill")
    }
    .buttonStyle(NotchCircularButtonStyle(size: 34, isPrimary: true, typography: .compact))
    .focusable()
    .accessibilityLabel(item.isPaused ? "Resume download" : "Pause download")
  }

  private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file)
  }
}

struct CompactBatteryView: View {
  let charging: BatteryChargingSnapshot
  let hardwareNotchWidth: CGFloat
  let hasPhysicalNotch: Bool
  let isPeek: Bool
  let onSelectSection: (NotchSection) -> Void

  var body: some View {
    VStack(spacing: 5) {
      if hasPhysicalNotch {
        HStack(spacing: 8) {
          batteryLabel
            .frame(maxWidth: .infinity, alignment: .leading)
          Color.clear.frame(width: max(hardwareNotchWidth - 20, 120))
          estimateLabel
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      } else {
        HStack(spacing: 9) {
          Image(systemName: "battery.100percent.bolt")
            .font(.system(size: isPeek ? 23 : 19, weight: .semibold))
            .dashboardTint(.green)
          batteryLabel
          Spacer(minLength: 8)
          estimateLabel
          Image(systemName: "chevron.down")
            .font(.caption.weight(.bold))
            .dashboardTertiaryText()
        }
      }

      if isPeek {
        HoverSectionNavigation(currentSection: .system, onSelect: onSelectSection)
      }
    }
    .padding(.horizontal, 11)
    .padding(.top, isPeek ? 5 : 4)
    .padding(.bottom, isPeek ? 7 : 5)
  }

  private var batteryLabel: some View {
    HStack(spacing: 6) {
      if hasPhysicalNotch {
        Image(systemName: "battery.100percent.bolt")
          .dashboardTint(.green)
      }
      Text("Charging")
        .font(.callout.weight(.semibold))
      Text("\(charging.level)%")
        .font(.caption.weight(.bold).monospacedDigit())
        .dashboardTint(.green)
    }
  }

  private var estimateLabel: some View {
    Text(charging.estimateLabel)
      .font(.callout.weight(.semibold).monospacedDigit())
      .dashboardSecondaryText()
      .lineLimit(1)
  }
}
