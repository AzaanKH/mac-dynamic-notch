import Foundation

// Categories follow the default presentation priority.
enum CompactActivityKind: String, CaseIterable, Identifiable {
  case agent, download, focus, music, battery

  var id: Self { self }

  var title: String {
    switch self {
    case .agent: "Agents"
    case .download: "Downloads"
    case .focus: "Timer"
    case .music: "Music"
    case .battery: "Battery"
    }
  }

  var symbolName: String {
    switch self {
    case .agent: "sparkles"
    case .download: "arrow.down.circle"
    case .focus: "timer"
    case .music: "music.note"
    case .battery: "battery.100percent.bolt"
    }
  }
}

struct CompactPresentation: Equatable {
  private(set) var available: [CompactActivityKind] = []
  private(set) var needsApproval = false
  private(set) var pinned: CompactActivityKind?
  private(set) var pinExpiresAt: Date?

  var primary: CompactActivityKind? {
    if needsApproval { return .agent }
    return pinned ?? available.first
  }

  var secondary: [CompactActivityKind] {
    available.filter { $0 != primary }
  }

  var showsIndicator: Bool { !secondary.isEmpty || pinned != nil }

  mutating func update(available: [CompactActivityKind], needsApproval: Bool, now: Date = .now) {
    self.available = CompactActivityKind.allCases.filter(available.contains)
    self.needsApproval = needsApproval
    if let pinned, !self.available.contains(pinned) || now >= (pinExpiresAt ?? now) {
      unpin()
    }
  }

  mutating func pin(_ kind: CompactActivityKind, now: Date = .now) {
    guard available.contains(kind) else { return }
    pinned = kind
    pinExpiresAt = now.addingTimeInterval(5 * 60)
  }

  mutating func unpin() {
    pinned = nil
    pinExpiresAt = nil
  }
}
