import Foundation

public enum BrowserMediaEventKind: String, Codable, Sendable {
  case update
  case ended
}

public struct BrowserMediaEvent: Codable, Equatable, Sendable {
  public let kind: BrowserMediaEventKind
  public let sessionID: String
  public let browserName: String
  public let title: String?
  public let artist: String?
  public let album: String?
  public let siteName: String?
  public let pageURL: URL?
  public let artworkURL: URL?
  public let artworkData: Data?
  public let isPlaying: Bool?
  public let duration: Double?
  public let position: Double?
  public let supportsPrevious: Bool?
  public let supportsNext: Bool?
  public let supportsSeeking: Bool?
  public let playbackRate: Double?

  public init(
    kind: BrowserMediaEventKind,
    sessionID: String,
    browserName: String,
    title: String? = nil,
    artist: String? = nil,
    album: String? = nil,
    siteName: String? = nil,
    pageURL: URL? = nil,
    artworkURL: URL? = nil,
    artworkData: Data? = nil,
    isPlaying: Bool? = nil,
    duration: Double? = nil,
    position: Double? = nil,
    supportsPrevious: Bool? = nil,
    supportsNext: Bool? = nil,
    supportsSeeking: Bool? = nil,
    playbackRate: Double? = nil
  ) {
    self.kind = kind
    self.sessionID = sessionID
    self.browserName = browserName
    self.title = title
    self.artist = artist
    self.album = album
    self.siteName = siteName
    self.pageURL = pageURL
    self.artworkURL = artworkURL
    self.artworkData = artworkData
    self.isPlaying = isPlaying
    self.duration = duration
    self.position = position
    self.supportsPrevious = supportsPrevious
    self.supportsNext = supportsNext
    self.supportsSeeking = supportsSeeking
    self.playbackRate = playbackRate
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case sessionID = "session_id"
    case browserName = "browser_name"
    case title
    case artist
    case album
    case siteName = "site_name"
    case pageURL = "page_url"
    case artworkURL = "artwork_url"
    case artworkData = "artwork_data"
    case isPlaying = "is_playing"
    case duration
    case position
    case supportsPrevious = "supports_previous"
    case supportsNext = "supports_next"
    case supportsSeeking = "supports_seeking"
    case playbackRate = "playback_rate"
  }

  public func validated() throws -> BrowserMediaEvent {
    guard pageURL.map({
      URLSchemeValidation.allows($0, schemes: ["https", "http"])
    }) ?? true,
      artworkURL.map({
        URLSchemeValidation.allows($0, schemes: ["https", "http"])
      }) ?? true
    else {
      throw BrowserMediaEventValidationError.invalidURL
    }
    guard (artworkData?.count ?? 0) <= 32_768 else {
      throw BrowserMediaEventValidationError.artworkTooLarge
    }
    return self
  }
}

public enum BrowserMediaEventValidationError: LocalizedError, Sendable {
  case invalidURL
  case artworkTooLarge

  public var errorDescription: String? {
    switch self {
    case .invalidURL: "page_url and artwork_url must use http or https"
    case .artworkTooLarge: "artwork_data must not exceed 32,768 bytes"
    }
  }
}

public enum BrowserMediaCommand: String, Codable, Sendable {
  case playPause = "play_pause"
  case previous
  case next
  case seek
}

public struct BrowserMediaBridgeResponse: Codable, Equatable, Sendable {
  public let status: String
  public let sessionID: String?
  public let command: BrowserMediaCommand?
  public let seekPosition: Double?

  public init(
    status: String,
    sessionID: String? = nil,
    command: BrowserMediaCommand? = nil,
    seekPosition: Double? = nil
  ) {
    self.status = status
    self.sessionID = sessionID
    self.command = command
    self.seekPosition = seekPosition
  }

  enum CodingKeys: String, CodingKey {
    case status
    case sessionID = "session_id"
    case command
    case seekPosition = "seek_position"
  }
}
