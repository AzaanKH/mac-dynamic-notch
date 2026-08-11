import Combine
import Foundation
import NotchRouterCore

enum ActivityGroup: String, CaseIterable, Identifiable {
  case active
  case attentionRequired = "attention_required"
  case completed

  var id: String { rawValue }
}

extension ActivityState {
  var activityGroup: ActivityGroup {
    switch self {
    case .queued, .running:
      .active
    case .needsApproval:
      .attentionRequired
    case .stale, .succeeded, .failed, .cancelled:
      .completed
    }
  }
}

@MainActor
final class ActivityStore: ObservableObject {
  static let expiryCheckInterval: TimeInterval = 30
  static let retentionPreferenceKey = "activityRetentionLimit"
  static let defaultRetentionLimit = 30
  static let availableRetentionLimits = [10, 30, 50, 100]

  @Published private(set) var activities: [AIActivity] = []
  @Published private(set) var retentionLimit: Int

  var onIngest: ((AIActivity) -> Void)?

  private let storageURL: URL
  private let expiryWindow: TimeInterval
  private let dateProvider: () -> Date
  private let defaults: UserDefaults

  init(
    storageURL: URL = AppPaths.activitiesFile,
    expiryWindow: TimeInterval = ActivityLiveness.defaultExpiryWindow,
    dateProvider: @escaping () -> Date = Date.init,
    defaults: UserDefaults = .standard
  ) {
    self.storageURL = storageURL
    self.expiryWindow = max(0, expiryWindow)
    self.dateProvider = dateProvider
    self.defaults = defaults
    retentionLimit = Self.normalizedRetentionLimit(
      defaults.integer(forKey: Self.retentionPreferenceKey)
    )
    secureStoragePermissions()
    load()
    if trimActivitiesIfNeeded() {
      persist()
    }
    expireStaleActivities()
  }

  var currentActivity: AIActivity? {
    activities.first(where: { $0.state == .needsApproval })
      ?? activities.first(where: { !$0.state.isTerminal })
      ?? activities.first
  }

  var activeActivity: AIActivity? {
    activities.first(where: { $0.state == .needsApproval })
      ?? activities.first(where: { !$0.state.isTerminal })
  }

  var activeCount: Int {
    activities.count { $0.state.activityGroup == .active }
  }

  func count(in group: ActivityGroup) -> Int {
    activities.count { $0.state.activityGroup == group }
  }

  func activities(
    in group: ActivityGroup,
    matching query: String = ""
  ) -> [AIActivity] {
    let terms = query
      .split(whereSeparator: \Character.isWhitespace)
      .map(String.init)

    return activities.filter { activity in
      guard activity.state.activityGroup == group else { return false }
      guard !terms.isEmpty else { return true }

      let searchableText = [
        activity.id,
        activity.source,
        activity.title,
        activity.message ?? "",
        activity.state.rawValue.replacingOccurrences(of: "_", with: " "),
        activity.state.activityGroup.rawValue.replacingOccurrences(of: "_", with: " "),
      ].joined(separator: " ")

      return terms.allSatisfy(searchableText.localizedCaseInsensitiveContains)
    }
  }

  @discardableResult
  func ingest(_ unvalidatedEvent: ActivityEventRequest) throws -> AIActivity {
    let event = try unvalidatedEvent.validated()
    let now = dateProvider()

    let activity: AIActivity
    let hasVisibleChanges: Bool
    if let index = activities.firstIndex(where: { $0.id == event.activityID }) {
      hasVisibleChanges = activities[index].apply(event, now: now)
      activity = activities[index]
    } else {
      activity = AIActivity(event: event, now: now)
      activities.append(activity)
      hasVisibleChanges = true
    }

    sortActivities()
    trimActivitiesIfNeeded()
    persist()
    if hasVisibleChanges {
      onIngest?(activity)
    }
    return activity
  }

  @discardableResult
  func expireStaleActivities(at expirationDate: Date? = nil) -> Bool {
    let now = expirationDate ?? dateProvider()
    var didExpire = false
    for index in activities.indices {
      didExpire =
        activities[index].expireIfNeeded(
          at: now,
          after: expiryWindow
        ) || didExpire
    }
    guard didExpire else { return false }
    sortActivities()
    persist()
    return true
  }

  func dismiss(_ id: String) {
    activities.removeAll { $0.id == id }
    persist()
  }

  func clearFinished() {
    activities.removeAll { $0.state.isTerminal }
    persist()
  }

  func setRetentionLimit(_ limit: Int) {
    let normalized = Self.normalizedRetentionLimit(limit)
    guard normalized != retentionLimit else { return }
    retentionLimit = normalized
    defaults.set(normalized, forKey: Self.retentionPreferenceKey)
    trimActivitiesIfNeeded()
    persist()
  }

  private func load() {
    do {
      let data = try Data(contentsOf: storageURL)
      activities = try ActivityCoding.makeDecoder().decode(
        [AIActivity].self,
        from: data
      )
      sortActivities()
    } catch CocoaError.fileReadNoSuchFile {
      activities = []
    } catch {
      activities = []
      NSLog("NotchRouter could not read its activity history: \(error)")
    }
  }

  private func sortActivities() {
    activities.sort { lhs, rhs in
      let lhsPriority = priority(of: lhs.state)
      let rhsPriority = priority(of: rhs.state)
      if lhsPriority != rhsPriority {
        return lhsPriority < rhsPriority
      }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  private func priority(of state: ActivityState) -> Int {
    switch state.activityGroup {
    case .attentionRequired:
      return 0
    case .active:
      return 1
    case .completed:
      return 2
    }
  }

  private func persist() {
    do {
      try preparePrivateStorageDirectory()
      let data = try ActivityCoding.makeEncoder(prettyPrinted: true)
        .encode(activities)
      try data.write(to: storageURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: storageURL.path
      )
    } catch {
      NSLog("NotchRouter could not persist its activity history: \(error)")
    }
  }

  private func secureStoragePermissions() {
    do {
      try preparePrivateStorageDirectory()
      if FileManager.default.fileExists(atPath: storageURL.path) {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: storageURL.path
        )
      }
    } catch {
      NSLog("NotchRouter could not secure its activity history: \(error)")
    }
  }

  private func preparePrivateStorageDirectory() throws {
    let directoryURL = storageURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )
  }

  @discardableResult
  private func trimActivitiesIfNeeded() -> Bool {
    guard activities.count > retentionLimit else { return false }
    activities.removeLast(activities.count - retentionLimit)
    return true
  }

  private static func normalizedRetentionLimit(_ value: Int) -> Int {
    guard value > 0 else { return defaultRetentionLimit }
    return min(max(value, 1), 200)
  }
}
