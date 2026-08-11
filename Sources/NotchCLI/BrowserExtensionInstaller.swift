import Foundation
import NotchRouterCore

enum BrowserExtensionInstaller {
  static let hostName = "com.notchrouter.browser_media"
  static let extensionID = "eelhjoihmcccgbleiekmpeabeijcemkb"

  static var extensionDirectory: URL {
    AppPaths.applicationSupportDirectory
      .appendingPathComponent("browser-extension", isDirectory: true)
  }

  static var installedHostURL: URL {
    AppPaths.applicationSupportDirectory
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent("notchrouter-browser-host")
  }

  static var manifestURLs: [URL] {
    let library = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return [
      "Google/Chrome/NativeMessagingHosts",
      "Microsoft Edge/NativeMessagingHosts",
      "BraveSoftware/Brave-Browser/NativeMessagingHosts",
      "Chromium/NativeMessagingHosts",
    ].map {
      library.appendingPathComponent($0, isDirectory: true)
        .appendingPathComponent("\(hostName).json")
    }
  }

  static func install() throws {
    let fileManager = FileManager.default
    let sourceHost = try locateHostExecutable()
    let sourceExtension = try locateExtensionDirectory()

    try AppPaths.prepareApplicationSupportDirectory()
    try fileManager.createDirectory(
      at: installedHostURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if sourceHost.standardizedFileURL != installedHostURL.standardizedFileURL {
      let executable = try Data(contentsOf: sourceHost, options: [.mappedIfSafe])
      try executable.write(to: installedHostURL, options: [.atomic])
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: installedHostURL.path
    )

    if fileManager.fileExists(atPath: extensionDirectory.path) {
      try fileManager.removeItem(at: extensionDirectory)
    }
    try fileManager.copyItem(at: sourceExtension, to: extensionDirectory)

    let manifest: [String: Any] = [
      "name": hostName,
      "description": "Passes active browser media to NotchRouter.",
      "path": installedHostURL.path,
      "type": "stdio",
      "allowed_origins": ["chrome-extension://\(extensionID)/"],
    ]
    var manifestData = try JSONSerialization.data(
      withJSONObject: manifest,
      options: [.prettyPrinted, .sortedKeys]
    )
    manifestData.append(0x0A)

    for manifestURL in manifestURLs {
      try fileManager.createDirectory(
        at: manifestURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try manifestData.write(to: manifestURL, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: manifestURL.path
      )
    }
  }

  static func remove() throws {
    let fileManager = FileManager.default
    for url in manifestURLs where fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    if fileManager.fileExists(atPath: installedHostURL.path) {
      try fileManager.removeItem(at: installedHostURL)
    }
    if fileManager.fileExists(atPath: extensionDirectory.path) {
      try fileManager.removeItem(at: extensionDirectory)
    }
  }

  static var isInstalled: Bool {
    let fileManager = FileManager.default
    return fileManager.isExecutableFile(atPath: installedHostURL.path)
      && fileManager.fileExists(
        atPath: extensionDirectory.appendingPathComponent("manifest.json").path
      )
      && manifestURLs.allSatisfy { fileManager.fileExists(atPath: $0.path) }
  }

  private static func locateHostExecutable() throws -> URL {
    let executableURL =
      Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidates = [
      executableURL.deletingLastPathComponent()
        .appendingPathComponent("notchrouter-browser-host"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/debug/notchrouter-browser-host"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/release/notchrouter-browser-host"),
    ]
    guard
      let result = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    else {
      throw BrowserInstallerError.missingHost
    }
    return result
  }

  private static func locateExtensionDirectory() throws -> URL {
    let executableURL =
      Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidates = [
      executableURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("BrowserExtension", isDirectory: true),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("BrowserExtension", isDirectory: true),
    ]
    guard
      let result = candidates.first(where: {
        FileManager.default.fileExists(
          atPath: $0.appendingPathComponent("manifest.json").path
        )
      })
    else {
      throw BrowserInstallerError.missingExtension
    }
    return result
  }
}

private enum BrowserInstallerError: LocalizedError {
  case missingHost
  case missingExtension

  var errorDescription: String? {
    switch self {
    case .missingHost:
      "The bundled browser native-messaging host was not found."
    case .missingExtension:
      "The bundled browser extension files were not found."
    }
  }
}
