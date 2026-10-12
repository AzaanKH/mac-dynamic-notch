import Foundation

public enum BrowserDownloadEventKind: String, Codable, Sendable {
  case update = "download_update"
  case removed = "download_removed"
  case heartbeat = "downloads_heartbeat"
  case disabled = "downloads_disabled"
}

public enum BrowserDownloadState: String, Codable, Sendable {
  case inProgress = "in_progress"
  case complete
  case interrupted
}

public struct BrowserDownloadEvent: Codable, Equatable, Sendable {
  public let kind: BrowserDownloadEventKind
  public let downloadID: Int
  public let browserName: String
  public let displayName: String?
  public let sourceHost: String?
  public let bytesReceived: Int64?
  public let totalBytes: Int64?
  public let estimatedEndTime: Date?
  public let state: BrowserDownloadState?
  public let isPaused: Bool?
  public let canResume: Bool?
  public let error: String?

  public init(
    kind: BrowserDownloadEventKind,
    downloadID: Int = 0,
    browserName: String,
    displayName: String? = nil,
    sourceHost: String? = nil,
    bytesReceived: Int64? = nil,
    totalBytes: Int64? = nil,
    estimatedEndTime: Date? = nil,
    state: BrowserDownloadState? = nil,
    isPaused: Bool? = nil,
    canResume: Bool? = nil,
    error: String? = nil
  ) {
    self.kind = kind
    self.downloadID = downloadID
    self.browserName = browserName
    self.displayName = displayName
    self.sourceHost = sourceHost
    self.bytesReceived = bytesReceived
    self.totalBytes = totalBytes
    self.estimatedEndTime = estimatedEndTime
    self.state = state
    self.isPaused = isPaused
    self.canResume = canResume
    self.error = error
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case downloadID = "download_id"
    case browserName = "browser_name"
    case displayName = "display_name"
    case sourceHost = "source_host"
    case bytesReceived = "bytes_received"
    case totalBytes = "total_bytes"
    case estimatedEndTime = "estimated_end_time"
    case state
    case isPaused = "is_paused"
    case canResume = "can_resume"
    case error
  }

  public func validated() throws -> BrowserDownloadEvent {
    let trimmedBrowserName = browserName.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !trimmedBrowserName.isEmpty, trimmedBrowserName.count <= 80 else {
      throw BrowserDownloadValidationError.invalidBrowserName
    }
    guard kind == .heartbeat || kind == .disabled || downloadID >= 0 else {
      throw BrowserDownloadValidationError.invalidDownloadID
    }
    guard (displayName?.count ?? 0) <= 4_096 else {
      throw BrowserDownloadValidationError.displayNameTooLong
    }
    guard (sourceHost?.count ?? 0) <= 4_096 else {
      throw BrowserDownloadValidationError.sourceHostTooLong
    }
    return self
  }
}

public enum BrowserDownloadValidationError: LocalizedError, Sendable {
  case invalidBrowserName
  case invalidDownloadID
  case displayNameTooLong
  case sourceHostTooLong

  public var errorDescription: String? {
    switch self {
    case .invalidBrowserName:
      "browser_name must contain 1–80 characters"
    case .invalidDownloadID:
      "download_id must not be negative"
    case .displayNameTooLong:
      "display_name must not exceed 4,096 characters"
    case .sourceHostTooLong:
      "source_host must not exceed 4,096 characters"
    }
  }
}

public enum BrowserDownloadCommandKind: String, Codable, Sendable {
  case pause
  case resume
  case cancel
  case reveal
}

public struct BrowserDownloadCommand: Codable, Equatable, Sendable {
  public let downloadID: Int
  public let action: BrowserDownloadCommandKind

  public init(downloadID: Int, action: BrowserDownloadCommandKind) {
    self.downloadID = downloadID
    self.action = action
  }

  enum CodingKeys: String, CodingKey {
    case downloadID = "download_id"
    case action
  }
}

public struct BrowserDownloadBridgeResponse: Codable, Equatable, Sendable {
  public let status: String
  public let command: BrowserDownloadCommand?

  public init(status: String, command: BrowserDownloadCommand? = nil) {
    self.status = status
    self.command = command
  }
}
