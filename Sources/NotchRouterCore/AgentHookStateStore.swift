import CryptoKit
import Foundation

/// Remembers what each hook last published, so identical updates are
/// coalesced into heartbeats and finished activities are not republished.
public struct AgentHookStateStore: Sendable {
  /// Shared by every agent; activity IDs keep them apart. The directory keeps
  /// its original name so existing Codex state still applies.
  public static let defaultDirectory = AppPaths.applicationSupportDirectory
    .appendingPathComponent("codex-adapter-state", isDirectory: true)

  private let directory: URL

  public init(directory: URL = defaultDirectory) {
    self.directory = directory
  }

  private struct Publication: Codable {
    let state: ActivityState
    let fingerprint: String
    /// When the published event's hook started. Absent in older files.
    var timestamp: Date?
  }

  /// Every hook run has its own timestamp, so it is left out: otherwise no
  /// two events would match and heartbeats would never be coalesced.
  private func fingerprint(_ event: ActivityEventRequest) throws -> String {
    var event = event
    event.timestamp = nil
    let encoder = ActivityCoding.makeEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(event))
      .map { String(format: "%02x", $0) }.joined()
  }

  private func previousPublication(for activityID: String) -> Publication? {
    guard let data = try? Data(contentsOf: stateURL(for: activityID)) else { return nil }
    return try? JSONDecoder().decode(Publication.self, from: data)
  }

  /// Whether `event` started before the last publication. Background hooks
  /// can finish out of order; a late one must not undo a newer state.
  private func isOutdated(_ event: ActivityEventRequest, comparedWith previous: Publication?) -> Bool {
    guard let started = event.timestamp, let latest = previous?.timestamp else { return false }
    return started < latest
  }

  public func shouldPublish(
    _ event: ActivityEventRequest,
    now: Date = Date()
  ) throws -> Bool {
    let activityID = event.activityID
    let previous = previousPublication(for: activityID)
    guard !isOutdated(event, comparedWith: previous) else { return false }
    // Ending a session only cancels work that is still in progress. A turn
    // that already finished, or was never shown, keeps its own state.
    if event.state == .cancelled {
      return previous.map { !$0.state.isTerminal } ?? false
    }
    // Legacy files contain only a state string. Publish once to upgrade them.
    guard let previous,
      previous.state == event.state,
      previous.fingerprint == (try fingerprint(event))
    else {
      return true
    }
    guard !event.state.isTerminal else {
      return false
    }
    guard
      let values = try? stateURL(for: activityID).resourceValues(
        forKeys: [.contentModificationDateKey]
      ),
      let lastPublishedAt = values.contentModificationDate
    else {
      return true
    }
    return now.timeIntervalSince(lastPublishedAt) >= ActivityLiveness.heartbeatInterval
  }

  public func record(_ event: ActivityEventRequest) throws {
    let activityID = event.activityID
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    cleanupExpiredFiles()
    let url = stateURL(for: activityID)
    let publication = Publication(
      state: event.state, fingerprint: try fingerprint(event), timestamp: event.timestamp
    )
    // Background hooks run in separate processes. Without the lock, a slower
    // hook that started earlier could pass the check, then write over a newer
    // publication recorded in between.
    try withExclusiveLock {
      guard !isOutdated(event, comparedWith: previousPublication(for: activityID)) else { return }
      try JSONEncoder().encode(publication).write(to: url, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
      )
    }
  }

  /// Serializes record's read, check, and write across hook processes. The
  /// kernel releases the lock if a holder exits, so a killed hook cannot
  /// leave it held.
  private func withExclusiveLock(_ body: () throws -> Void) throws {
    let path = directory.appendingPathComponent(".lock").path
    let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    try body()
  }

  private func stateURL(for activityID: String) -> URL {
    let digest = SHA256.hash(data: Data(activityID.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return directory.appendingPathComponent("\(digest).state")
  }

  private func cleanupExpiredFiles() {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }
    let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    for file in files where file.pathExtension == "state" {
      guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
        let modifiedAt = values.contentModificationDate,
        modifiedAt < cutoff
      else {
        continue
      }
      try? FileManager.default.removeItem(at: file)
    }
  }
}
