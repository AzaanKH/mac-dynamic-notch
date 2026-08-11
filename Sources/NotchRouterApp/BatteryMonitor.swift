import Combine
import Foundation
import IOKit.ps

enum ChargingEstimate: Equatable, Sendable {
  case calculating
  case minutes(Int)
}

struct BatteryChargingSnapshot: Equatable, Sendable {
  let level: Int
  let estimate: ChargingEstimate

  var estimateLabel: String {
    switch estimate {
    case .calculating:
      "Calculating…"
    case .minutes(let minutes):
      if minutes < 60 {
        "\(minutes)m until full"
      } else {
        "\(minutes / 60)h \(minutes % 60)m until full"
      }
    }
  }
}

@MainActor
final class BatteryMonitor: ObservableObject {
  @Published private(set) var charging: BatteryChargingSnapshot?

  var onChange: (() -> Void)?

  nonisolated(unsafe) private var notificationSource: CFRunLoopSource?

  init() {
    refresh()
    let context = Unmanaged.passUnretained(self).toOpaque()
    if let source = IOPSNotificationCreateRunLoopSource(
      batteryPowerSourceDidChange,
      context
    )?.takeRetainedValue() {
      notificationSource = source
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
  }

  deinit {
    if let notificationSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
    }
  }

  func refresh() {
    let updatedCharging = Self.readChargingSnapshot()
    guard updatedCharging != charging else { return }
    charging = updatedCharging
    onChange?()
  }

  private static func readChargingSnapshot() -> BatteryChargingSnapshot? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sourceList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
        as? [CFTypeRef]
    else { return nil }

    for source in sourceList {
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?
          .takeUnretainedValue() as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        description[kIOPSIsChargingKey] as? Bool == true
      else { continue }

      let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
        ?? 0
      let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
        ?? 100
      let level = maximum > 0
        ? Int((current / maximum * 100).rounded())
        : Int(current.rounded())
      let minutes = (description[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue
        ?? -1
      let estimate: ChargingEstimate = minutes >= 0
        ? .minutes(minutes)
        : .calculating
      return BatteryChargingSnapshot(
        level: min(max(level, 0), 100),
        estimate: estimate
      )
    }
    return nil
  }
}

private func batteryPowerSourceDidChange(_ context: UnsafeMutableRawPointer?) {
  guard let context else { return }
  let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context)
    .takeUnretainedValue()
  Task { @MainActor in
    monitor.refresh()
  }
}
