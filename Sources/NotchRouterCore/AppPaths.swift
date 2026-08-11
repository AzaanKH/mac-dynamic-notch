import Foundation
import Security

public enum AppPaths {
  public static var applicationSupportDirectory: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return base.appendingPathComponent("NotchRouter", isDirectory: true)
  }

  public static var activitiesFile: URL {
    applicationSupportDirectory.appendingPathComponent("activities.json")
  }

  public static var tokenFile: URL {
    applicationSupportDirectory.appendingPathComponent("integration-token")
  }

  public static var fileShelfFile: URL {
    applicationSupportDirectory.appendingPathComponent("file-shelf.json")
  }

  public static var clipboardFile: URL {
    applicationSupportDirectory.appendingPathComponent("clipboard.json")
  }

  public static func prepareApplicationSupportDirectory() throws {
    try FileManager.default.createDirectory(
      at: applicationSupportDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: applicationSupportDirectory.path
    )
  }
}

public enum IntegrationToken {
  public static func loadOrCreate() throws -> String {
    try AppPaths.prepareApplicationSupportDirectory()

    if let existing = try? String(
      contentsOf: AppPaths.tokenFile,
      encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines),
      existing.count >= 32
    {
      return existing
    }

    return try writeNewToken()
  }

  public static func rotate() throws -> String {
    try AppPaths.prepareApplicationSupportDirectory()
    return try writeNewToken()
  }

  private static func writeNewToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw TokenError.generationFailed(status)
    }

    let token = bytes.map { String(format: "%02x", $0) }.joined()
    try token.write(
      to: AppPaths.tokenFile,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: AppPaths.tokenFile.path
    )
    return token
  }

  public enum TokenError: LocalizedError {
    case generationFailed(OSStatus)

    public var errorDescription: String? {
      switch self {
      case .generationFailed(let status):
        "Could not generate an integration token (Security error \(status))."
      }
    }
  }
}

public enum ActivityCoding {
  public static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if prettyPrinted {
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    return encoder
  }

  public static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
