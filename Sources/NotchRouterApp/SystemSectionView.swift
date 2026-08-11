import SwiftUI

struct SystemSectionView: View {
  @ObservedObject var monitor: SystemMonitorController

  private let columns = [
    GridItem(.flexible(), spacing: 8),
    GridItem(.flexible(), spacing: 8),
  ]

  var body: some View {
    Group {
      if monitor.isEnabled {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 8) {
            metricCard(
              title: "CPU",
              value: monitor.system.cpuUsage.formatted(.percent.precision(.fractionLength(0))),
              detail: "Overall usage",
              symbol: "cpu",
              tint: .cyan,
              progress: monitor.system.cpuUsage
            )
            metricCard(
              title: "Memory",
              value: bytes(monitor.system.memoryUsed),
              detail: "\(monitor.system.memoryPressure.rawValue) pressure",
              symbol: "memorychip",
              tint: memoryPressureTint,
              progress: ratio(
                monitor.system.memoryUsed,
                monitor.system.memoryTotal
              )
            )
            metricCard(
              title: "Disk free",
              value: bytes(monitor.system.diskFree),
              detail: "of \(bytes(monitor.system.diskTotal))",
              symbol: "internaldrive",
              tint: .blue,
              progress: ratio(
                UInt64(max(monitor.system.diskTotal - monitor.system.diskFree, 0)),
                UInt64(max(monitor.system.diskTotal, 0))
              )
            )
            metricCard(
              title: "Thermal",
              value: monitor.system.thermalCondition.rawValue,
              detail: monitor.system.isLowPowerModeEnabled
                ? "Low Power Mode on"
                : "Low Power Mode off",
              symbol: "thermometer.medium",
              tint: thermalTint,
              progress: nil
            )
          }

          networkCard
            .padding(.top, 8)
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 8)
      } else {
        VStack(spacing: 10) {
          Image(systemName: "gauge.with.dots.needle.33percent")
            .font(.system(size: 28, weight: .light))
            .dashboardSecondaryText()
          Text("System monitoring is off")
            .font(.headline)
          Text("Enable lightweight local CPU, memory, disk, thermal, and network metrics.")
            .font(.callout)
            .dashboardSecondaryText()
            .multilineTextAlignment(.center)
          Button("Enable System Section") {
            monitor.setEnabled(true)
          }
          .buttonStyle(NotchAccentButtonStyle(tint: .cyan))
          .focusable()
        }
        .padding(24)
      }
    }
  }

  private func metricCard(
    title: String,
    value: String,
    detail: String,
    symbol: String,
    tint: Color,
    progress: Double?
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .font(.caption.weight(.bold))
          .dashboardTint(tint)
        Text(title)
          .font(.caption.weight(.semibold))
          .dashboardSecondaryText()
        Spacer()
      }
      Text(value)
        .font(.title3.weight(.bold).monospacedDigit())
        .lineLimit(1)
      Text(detail)
        .font(.caption)
        .dashboardTertiaryText()
        .lineLimit(1)
      if let progress {
        ProgressView(value: progress)
          .tint(tint)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(11)
    .dashboardSurface(cornerRadius: 13)
  }

  private var networkCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 7) {
        Image(systemName: monitor.network.isOnline ? "network" : "wifi.slash")
          .dashboardTint(monitor.network.isOnline ? .green : .orange)
        VStack(alignment: .leading, spacing: 1) {
          Text(monitor.network.isOnline ? monitor.network.interfaceName : "Offline")
            .font(.callout.weight(.semibold))
          Text(networkDetails)
            .font(.caption)
            .dashboardSecondaryText()
        }
        Spacer()
        if let wifiSignal = monitor.network.wifiSignal {
          Text("\(wifiSignal) dBm")
            .font(.caption.weight(.semibold).monospacedDigit())
            .dashboardSecondaryText()
        }
      }

      HStack(spacing: 8) {
        throughputMetric(
          symbol: "arrow.down",
          value: rate(monitor.network.downloadBytesPerSecond),
          total: bytes(monitor.network.receivedSinceLaunch),
          tint: .green
        )
        throughputMetric(
          symbol: "arrow.up",
          value: rate(monitor.network.uploadBytesPerSecond),
          total: bytes(monitor.network.sentSinceLaunch),
          tint: .blue
        )
      }

      HStack(spacing: 8) {
        Button("Test connection") {
          monitor.testConnection()
        }
        .buttonStyle(NotchSubtleButtonStyle())
        .focusable()
        .disabled(!monitor.network.isOnline || monitor.connectionTest == .testing)

        connectionTestStatus
        Spacer()
        Text("On demand · contacts Apple")
          .font(.caption2)
          .dashboardTertiaryText()
      }
    }
    .padding(11)
    .dashboardSurface(cornerRadius: 13)
  }

  private func throughputMetric(
    symbol: String,
    value: String,
    total: String,
    tint: Color
  ) -> some View {
    HStack(spacing: 7) {
      Image(systemName: symbol)
        .font(.caption.weight(.bold))
        .dashboardTint(tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(value)
          .font(.callout.weight(.semibold).monospacedDigit())
        Text("\(total) since launch")
          .font(.caption2)
          .dashboardTertiaryText()
      }
      Spacer()
    }
    .padding(8)
    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
  }

  @ViewBuilder
  private var connectionTestStatus: some View {
    switch monitor.connectionTest {
    case .idle:
      EmptyView()
    case .testing:
      ProgressView()
        .controlSize(.small)
    case .success(let milliseconds):
      Text("\(milliseconds) ms")
        .font(.caption.weight(.semibold).monospacedDigit())
        .dashboardTint(.green)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .dashboardTint(.orange)
        .help(connectionFailureMessage)
    }
  }

  private var connectionFailureMessage: String {
    if case .failed(let message) = monitor.connectionTest {
      return message
    }
    return ""
  }

  private var networkDetails: String {
    var details: [String] = []
    if monitor.network.hasVPN { details.append("VPN") }
    if monitor.network.isConstrained { details.append("Constrained") }
    if monitor.network.isExpensive { details.append("Expensive") }
    return details.isEmpty ? "Local connection status" : details.joined(separator: " · ")
  }

  private var memoryPressureTint: Color {
    switch monitor.system.memoryPressure {
    case .normal: .green
    case .warning: .orange
    case .critical: .red
    }
  }

  private var thermalTint: Color {
    switch monitor.system.thermalCondition {
    case .nominal: .green
    case .fair: .yellow
    case .serious: .orange
    case .critical: .red
    }
  }

  private func ratio<T: BinaryInteger>(_ numerator: T, _ denominator: T) -> Double {
    guard denominator > 0 else { return 0 }
    return min(max(Double(numerator) / Double(denominator), 0), 1)
  }

  private func bytes<T: BinaryInteger>(_ value: T) -> String {
    ByteCountFormatter.string(
      fromByteCount: Int64(clamping: value),
      countStyle: .file
    )
  }

  private func rate(_ value: Double) -> String {
    guard value >= 1 else { return "0 B/s" }
    return "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))/s"
  }
}
