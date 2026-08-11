import AppKit
import Foundation
import NotchRouterCore
import Testing

@testable import NotchRouterApp

@MainActor
@Test
func clipboardPollingFollowsEnabledPreference() {
  let suiteName = "ClipboardPollingTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let pasteboard = NSPasteboard(
    name: NSPasteboard.Name("ClipboardPollingTests.\(UUID().uuidString)")
  )
  let storageURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(UUID().uuidString).json")
  let store = ClipboardStore(
    storageURL: storageURL,
    pasteboard: pasteboard,
    defaults: defaults
  )

  #expect(store.isEnabled == false)
  #expect(store.isPolling == false)

  store.setEnabled(true)
  #expect(store.isEnabled == true)
  #expect(store.isPolling == true)

  store.setEnabled(false)
  #expect(store.isEnabled == false)
  #expect(store.isPolling == false)
}

@MainActor
@Test
func clipboardPollingUsesLowerFrequency() {
  #expect(ClipboardStore.pollingInterval == 1.5)
}

@MainActor
@Test
func clipboardPreservesWhitespaceAndMarksTruncatedText() throws {
  let suiteName = "ClipboardTextTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipboardTextTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: rootURL,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: rootURL) }

  let pasteboard = NSPasteboard(
    name: NSPasteboard.Name("ClipboardTextTests.\(UUID().uuidString)")
  )
  let storageURL = rootURL.appendingPathComponent("clipboard.json")
  let store = ClipboardStore(
    storageURL: storageURL,
    pasteboard: pasteboard,
    defaults: defaults
  )
  store.setEnabled(true)

  let text = "  let value = 1\n\treturn value\n"
  pasteboard.clearContents()
  pasteboard.setString(text, forType: .string)
  store.captureIfChanged()

  #expect(store.entries.first?.text == text)
  #expect(store.entries.first?.isTextTruncated == false)

  pasteboard.clearContents()
  pasteboard.setString(" \n\t ", forType: .string)
  store.captureIfChanged()
  #expect(store.entries.count == 1)

  let limitText = String(
    repeating: "x",
    count: ClipboardStore.maximumTextLength
  )
  pasteboard.clearContents()
  pasteboard.setString(limitText, forType: .string)
  store.captureIfChanged()
  #expect(store.entries.first?.isTextTruncated == false)

  let longText = limitText + "tail"
  pasteboard.clearContents()
  pasteboard.setString(longText, forType: .string)
  store.captureIfChanged()

  let truncatedEntry = try #require(store.entries.first)
  #expect(truncatedEntry.text == String(longText.prefix(ClipboardStore.maximumTextLength)))
  #expect(truncatedEntry.isTextTruncated)

  store.copy(truncatedEntry)
  #expect(pasteboard.string(forType: .string) == truncatedEntry.text)
  store.setEnabled(false)

  let reloadedStore = ClipboardStore(
    storageURL: storageURL,
    pasteboard: pasteboard,
    defaults: defaults
  )
  #expect(reloadedStore.entries.first?.isTextTruncated == true)
  #expect(reloadedStore.entries.contains { $0.text == text })
}

@MainActor
@Test
func clipboardCapturesPersistsAndCopiesImages() throws {
  let suiteName = "ClipboardImageTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipboardImageTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: rootURL,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: rootURL) }

  let storageURL = rootURL.appendingPathComponent("clipboard.json")
  let pasteboard = NSPasteboard(
    name: NSPasteboard.Name("ClipboardImageTests.\(UUID().uuidString)")
  )
  let store = ClipboardStore(
    storageURL: storageURL,
    pasteboard: pasteboard,
    defaults: defaults
  )
  store.setEnabled(true)

  let imageData = try #require(makeTestPNG())
  pasteboard.clearContents()
  pasteboard.setData(imageData, forType: .png)
  store.captureIfChanged()

  let entry = try #require(store.entries.first)
  #expect(entry.isImage)
  #expect(entry.text == nil)
  #expect(entry.imagePixelWidth == 4)
  #expect(entry.imagePixelHeight == 3)
  #expect(store.image(for: entry) != nil)

  let reloadedStore = ClipboardStore(
    storageURL: storageURL,
    pasteboard: pasteboard,
    defaults: defaults
  )
  let reloadedEntry = try #require(reloadedStore.entries.first)
  #expect(reloadedEntry.id == entry.id)
  #expect(reloadedEntry.imageFileName == entry.imageFileName)
  #expect(reloadedEntry.imagePixelWidth == entry.imagePixelWidth)
  #expect(reloadedEntry.imagePixelHeight == entry.imagePixelHeight)
  #expect(reloadedStore.image(for: reloadedEntry) != nil)

  reloadedStore.copy(reloadedEntry)
  #expect(pasteboard.canReadObject(forClasses: [NSImage.self]))

  store.setEnabled(false)
  reloadedStore.setEnabled(false)
}

@MainActor
@Test
func clipboardLoadsLegacyTextEntries() throws {
  let suiteName = "ClipboardLegacyTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipboardLegacyTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: rootURL,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: rootURL) }

  let storageURL = rootURL.appendingPathComponent("clipboard.json")
  let id = UUID()
  let legacyJSON = """
    [{
      "id": "\(id.uuidString)",
      "text": "Still here",
      "sourceApplication": "TextEdit",
      "createdAt": "2026-08-07T12:00:00Z"
    }]
    """
  try Data(legacyJSON.utf8).write(to: storageURL)

  let store = ClipboardStore(
    storageURL: storageURL,
    pasteboard: NSPasteboard(
      name: NSPasteboard.Name("ClipboardLegacyTests.\(UUID().uuidString)")
    ),
    defaults: defaults
  )

  #expect(store.entries.count == 1)
  #expect(store.entries.first?.id == id)
  #expect(store.entries.first?.text == "Still here")
  #expect(store.entries.first?.isImage == false)
  #expect(store.entries.first?.isTextTruncated == false)
}

@MainActor
@Test
func clipboardRetentionLimitTrimsAndPersistsImmediately() throws {
  let suiteName = "ClipboardRetentionTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipboardRetentionTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: rootURL,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: rootURL) }

  let storageURL = rootURL.appendingPathComponent("clipboard.json")
  let pasteboard = NSPasteboard(
    name: NSPasteboard.Name("ClipboardRetentionTests.\(UUID().uuidString)")
  )
  let store = ClipboardStore(
    storageURL: storageURL,
    pasteboard: pasteboard,
    defaults: defaults
  )
  store.setEnabled(true)

  for index in 0..<5 {
    pasteboard.clearContents()
    pasteboard.setString("Clip \(index)", forType: .string)
    store.captureIfChanged()
  }

  store.setRetentionLimit(2)

  #expect(store.retentionLimit == 2)
  #expect(store.entries.compactMap(\.text) == ["Clip 4", "Clip 3"])

  store.setEnabled(false)
  let reloadedStore = ClipboardStore(
    storageURL: storageURL,
    pasteboard: pasteboard,
    defaults: defaults
  )
  #expect(reloadedStore.retentionLimit == 2)
  #expect(reloadedStore.entries.compactMap(\.text) == ["Clip 4", "Clip 3"])
}

@Test
func clipboardSearchMatchesTextTypeAndSourceApp() {
  let entry = ClipboardEntry(
    id: UUID(),
    text: "Résumé for the launch plan",
    sourceApplication: "TextEdit",
    sourceApplicationBundleIdentifier: "com.apple.TextEdit",
    createdAt: Date()
  )
  let image = ClipboardEntry(
    id: UUID(),
    imageFileName: "preview.png",
    imagePixelWidth: 200,
    imagePixelHeight: 100,
    sourceApplication: "Preview",
    createdAt: Date()
  )

  #expect(entry.matchesSearch("resume"))
  #expect(entry.matchesSearch("textedit"))
  #expect(!entry.matchesSearch("preview"))
  #expect(image.matchesSearch("image"))
  #expect(image.matchesSearch("preview"))
}

@MainActor
@Test
func clipboardPinsPersistAndStayOutsideRetentionLimit() throws {
  let suiteName = "ClipboardPinTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipboardPinTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: rootURL) }

  let pasteboard = NSPasteboard(
    name: NSPasteboard.Name("ClipboardPinTests.\(UUID().uuidString)")
  )
  let storageURL = rootURL.appendingPathComponent("clipboard.json")
  let store = ClipboardStore(
    storageURL: storageURL,
    pasteboard: pasteboard,
    defaults: defaults
  )
  store.setEnabled(true)
  for index in 0..<3 {
    pasteboard.clearContents()
    pasteboard.setString("Clip \(index)", forType: .string)
    store.captureIfChanged()
  }

  let oldest = try #require(store.entries.first(where: { $0.text == "Clip 0" }))
  store.togglePinned(oldest.id)
  store.setRetentionLimit(1)

  #expect(store.entries.compactMap(\.text) == ["Clip 0", "Clip 2"])
  #expect(store.entries.first?.isPinned == true)

  store.setEnabled(false)
  let reloadedStore = ClipboardStore(
    storageURL: storageURL,
    pasteboard: pasteboard,
    defaults: defaults
  )
  #expect(reloadedStore.entries.compactMap(\.text) == ["Clip 0", "Clip 2"])
  #expect(reloadedStore.entries.first?.isPinned == true)
}

@MainActor
@Test
func clipboardAutoExpiryPreservesPinnedEntries() throws {
  let suiteName = "ClipboardExpiryTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(
    ClipboardAutoExpiry.oneDay.rawValue,
    forKey: ClipboardStore.autoExpiryPreferenceKey
  )

  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipboardExpiryTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: rootURL) }
  let storageURL = rootURL.appendingPathComponent("clipboard.json")
  let oldDate = Date().addingTimeInterval(-2 * 86_400)
  let recentDate = Date().addingTimeInterval(-3_600)
  let entries = [
    ClipboardEntry(
      id: UUID(),
      text: "Pinned old clip",
      sourceApplication: "Notes",
      createdAt: oldDate,
      isPinned: true
    ),
    ClipboardEntry(
      id: UUID(),
      text: "Expired clip",
      sourceApplication: "Notes",
      createdAt: oldDate
    ),
    ClipboardEntry(
      id: UUID(),
      text: "Recent clip",
      sourceApplication: "Notes",
      createdAt: recentDate
    ),
  ]
  try ActivityCoding.makeEncoder().encode(entries).write(to: storageURL)

  let store = ClipboardStore(
    storageURL: storageURL,
    pasteboard: NSPasteboard(
      name: NSPasteboard.Name("ClipboardExpiryTests.\(UUID().uuidString)")
    ),
    defaults: defaults
  )

  #expect(store.entries.compactMap(\.text) == ["Pinned old clip", "Recent clip"])
  #expect(store.entries.first?.isPinned == true)
  store.setAutoExpiry(.never)
}

@MainActor
@Test
func clipboardAppExclusionsPersistByBundleIdentifier() {
  let suiteName = "ClipboardExclusionTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let storageURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipboardExclusionTests-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: storageURL) }

  let store = ClipboardStore(
    storageURL: storageURL,
    pasteboard: NSPasteboard(
      name: NSPasteboard.Name("ClipboardExclusionTests.\(UUID().uuidString)")
    ),
    defaults: defaults
  )
  store.excludeApplication(bundleIdentifier: "com.example.Secret", name: "Secret App")
  store.excludeApplication(bundleIdentifier: "com.example.Other", name: "Another App")

  #expect(store.excludedApplications.map(\.name) == ["Another App", "Secret App"])

  let reloadedStore = ClipboardStore(
    storageURL: storageURL,
    pasteboard: NSPasteboard(
      name: NSPasteboard.Name("ClipboardExclusionTests.Reloaded.\(UUID().uuidString)")
    ),
    defaults: defaults
  )
  #expect(
    reloadedStore.excludedApplications.map(\.bundleIdentifier)
      == ["com.example.Other", "com.example.Secret"]
  )

  reloadedStore.removeExcludedApplication("com.example.Secret")
  #expect(reloadedStore.excludedApplications.map(\.bundleIdentifier) == ["com.example.Other"])
}

@MainActor
private func makeTestPNG() -> Data? {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 4,
      pixelsHigh: 3,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  else { return nil }

  for x in 0..<4 {
    for y in 0..<3 {
      bitmap.setColor(
        NSColor(deviceRed: 0.45, green: 0.2, blue: 0.8, alpha: 1),
        atX: x,
        y: y
      )
    }
  }
  return bitmap.representation(using: .png, properties: [:])
}
