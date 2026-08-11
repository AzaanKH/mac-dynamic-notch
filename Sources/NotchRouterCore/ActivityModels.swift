import Foundation

enum URLSchemeValidation {
  static func allows(_ url: URL, schemes: Set<String>) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return schemes.contains(scheme)
  }
}

public enum ActivityState: String, Codable, CaseIterable, Sendable {
  case queued
  case running
  case needsApproval = "needs_approval"
  case stale
  case succeeded
  case failed
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .stale, .succeeded, .failed, .cancelled:
      true
    case .queued, .running, .needsApproval:
      false
    }
  }
}

public enum ActivityLiveness {
  /// Nonterminal activities are disconnected after this long without an accepted update.
  public static let defaultExpiryWindow: TimeInterval = 5 * 60

  /// Adapters may coalesce identical heartbeats to this cadence.
  public static let heartbeatInterval: TimeInterval = 60
}

public struct ActivityEventRequest: Codable, Sendable {
  public var activityID: String
  public var source: String
  public var title: String
  public var state: ActivityState
  public var message: String?
  public var progress: Double?
  public var actionURL: URL?
  public var timestamp: Date?

  public init(
    activityID: String,
    source: String,
    title: String,
    state: ActivityState,
    message: String? = nil,
    progress: Double? = nil,
    actionURL: URL? = nil,
    timestamp: Date? = nil
  ) {
    self.activityID = activityID
    self.source = source
    self.title = title
    self.state = state
    self.message = message
    self.progress = progress
    self.actionURL = actionURL
    self.timestamp = timestamp
  }

  private enum CodingKeys: String, CodingKey {
    case activityID = "activity_id"
    case source
    case title
    case state
    case message
    case progress
    case actionURL = "action_url"
    case timestamp
  }

  public func validated() throws -> ActivityEventRequest {
    var copy = self
    copy.activityID = activityID.trimmingCharacters(in: .whitespacesAndNewlines)
    copy.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
    copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    copy.message =
      message?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty

    guard !copy.activityID.isEmpty, copy.activityID.count <= 128 else {
      throw ActivityValidationError.invalidActivityID
    }
    guard !copy.source.isEmpty, copy.source.count <= 80 else {
      throw ActivityValidationError.invalidSource
    }
    guard !copy.title.isEmpty, copy.title.count <= 160 else {
      throw ActivityValidationError.invalidTitle
    }
    guard (copy.message?.count ?? 0) <= 1_000 else {
      throw ActivityValidationError.messageTooLong
    }
    if let progress = copy.progress {
      guard progress.isFinite else {
        throw ActivityValidationError.invalidProgress
      }
      copy.progress = min(max(progress, 0), 1)
    }
    if let actionURL = copy.actionURL {
      guard URLSchemeValidation.allows(
        actionURL,
        schemes: ["https", "http", "file", "x-apple.systempreferences"]
      ) else {
        throw ActivityValidationError.invalidActionURL
      }
    }
    return copy
  }
}

public enum ActivityValidationError: LocalizedError, Sendable {
  case invalidActivityID
  case invalidSource
  case invalidTitle
  case messageTooLong
  case invalidProgress
  case invalidActionURL

  public var errorDescription: String? {
    switch self {
    case .invalidActivityID:
      "activity_id must contain 1–128 characters"
    case .invalidSource:
      "source must contain 1–80 characters"
    case .invalidTitle:
      "title must contain 1–160 characters"
    case .messageTooLong:
      "message must not exceed 1,000 characters"
    case .invalidProgress:
      "progress must be a finite number"
    case .invalidActionURL:
      "action_url uses an unsupported URL scheme"
    }
  }
}

public struct ActivityUpdate: Codable, Identifiable, Sendable {
  public let id: UUID
  public let state: ActivityState
  public let message: String?
  public let timestamp: Date

  public init(
    id: UUID = UUID(),
    state: ActivityState,
    message: String?,
    timestamp: Date
  ) {
    self.id = id
    self.state = state
    self.message = message
    self.timestamp = timestamp
  }
}

public struct AIActivity: Codable, Identifiable, Sendable {
  public let id: String
  public var source: String
  public var title: String
  public var state: ActivityState
  public var message: String?
  public var progress: Double?
  public var actionURL: URL?
  public let startedAt: Date
  public var updatedAt: Date
  public var lastHeartbeatAt: Date
  public var history: [ActivityUpdate]

  private enum CodingKeys: String, CodingKey {
    case id
    case source
    case title
    case state
    case message
    case progress
    case actionURL = "action_url"
    case startedAt = "started_at"
    case updatedAt = "updated_at"
    case lastHeartbeatAt = "last_heartbeat_at"
    case history
  }

  public init(event: ActivityEventRequest, now: Date = Date()) {
    let timestamp = event.timestamp ?? now
    id = event.activityID
    source = event.source
    title = event.title
    state = event.state
    message = event.message
    progress = event.progress
    actionURL = event.actionURL
    startedAt = timestamp
    updatedAt = timestamp
    lastHeartbeatAt = now
    history = [
      ActivityUpdate(
        state: event.state,
        message: event.message,
        timestamp: timestamp
      )
    ]
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    source = try container.decode(String.self, forKey: .source)
    title = try container.decode(String.self, forKey: .title)
    state = try container.decode(ActivityState.self, forKey: .state)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    progress = try container.decodeIfPresent(Double.self, forKey: .progress)
    actionURL = try container.decodeIfPresent(URL.self, forKey: .actionURL)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    lastHeartbeatAt =
      try container.decodeIfPresent(Date.self, forKey: .lastHeartbeatAt)
      ?? updatedAt
    history = try container.decode([ActivityUpdate].self, forKey: .history)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(source, forKey: .source)
    try container.encode(title, forKey: .title)
    try container.encode(state, forKey: .state)
    try container.encodeIfPresent(message, forKey: .message)
    try container.encodeIfPresent(progress, forKey: .progress)
    try container.encodeIfPresent(actionURL, forKey: .actionURL)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(lastHeartbeatAt, forKey: .lastHeartbeatAt)
    try container.encode(history, forKey: .history)
  }

  /// Applies an update and returns whether the user-visible activity changed.
  /// Identical updates still refresh liveness without adding redundant history.
  @discardableResult
  public mutating func apply(_ event: ActivityEventRequest, now: Date = Date()) -> Bool {
    let timestamp = event.timestamp ?? now
    let wasStale = state == .stale
    let effectiveTimestamp =
      wasStale
      ? max(timestamp, max(now, updatedAt))
      : timestamp
    lastHeartbeatAt = max(lastHeartbeatAt, now)

    let resolvedActionURL = event.actionURL ?? actionURL
    let hasVisibleChanges =
      source != event.source
      || title != event.title
      || state != event.state
      || message != event.message
      || progress != event.progress
      || actionURL != resolvedActionURL

    if hasVisibleChanges {
      appendHistory(
        ActivityUpdate(
          state: event.state,
          message: event.message,
          timestamp: effectiveTimestamp
        )
      )
    }

    // A fresh delivery can reconnect an expired activity even when an integration
    // reuses an older semantic timestamp.
    guard effectiveTimestamp >= updatedAt else {
      return false
    }

    source = event.source
    title = event.title
    state = event.state
    message = event.message
    progress = event.progress
    actionURL = resolvedActionURL
    updatedAt = effectiveTimestamp
    return hasVisibleChanges
  }

  /// Moves a nonterminal activity to a recoverable disconnected state when heartbeats stop.
  @discardableResult
  public mutating func expireIfNeeded(
    at now: Date = Date(),
    after expiryWindow: TimeInterval = ActivityLiveness.defaultExpiryWindow
  ) -> Bool {
    guard !state.isTerminal,
      now.timeIntervalSince(lastHeartbeatAt) >= max(0, expiryWindow)
    else {
      return false
    }

    let disconnectedMessage = "No heartbeat received; the activity may be disconnected."
    let expirationTimestamp = max(updatedAt, now)
    state = .stale
    message = disconnectedMessage
    updatedAt = expirationTimestamp
    appendHistory(
      ActivityUpdate(
        state: .stale,
        message: disconnectedMessage,
        timestamp: expirationTimestamp
      )
    )
    return true
  }

  private mutating func appendHistory(_ update: ActivityUpdate) {
    history.append(update)
    history.sort { $0.timestamp < $1.timestamp }
    if history.count > 40 {
      history.removeFirst(history.count - 40)
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
