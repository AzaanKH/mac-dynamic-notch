import AppKit
import Combine
import Foundation
import NotchRouterCore
import UniformTypeIdentifiers

enum ClipboardAutoExpiry: Int, CaseIterable, Identifiable {
  case never = 0
  case oneHour = 3_600
  case oneDay = 86_400
  case sevenDays = 604_800
  case thirtyDays = 2_592_000

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .never: "Never"
    case .oneHour: "After 1 hour"
    case .oneDay: "After 1 day"
    case .sevenDays: "After 7 days"
    case .thirtyDays: "After 30 days"
    }
  }

  var interval: TimeInterval? {
    self == .never ? nil : TimeInterval(rawValue)
  }
}

struct ClipboardExcludedApplication: Codable, Identifiable, Equatable {
  let bundleIdentifier: String
  let name: String

  var id: String { bundleIdentifier }
}

struct ClipboardEntry: Codable, Identifiable, Equatable {
  let id: UUID
  let text: String?
  let imageFileName: String?
  let imagePixelWidth: Int?
  let imagePixelHeight: Int?
  let imageByteCount: Int?
  let sourceApplication: String?
  let sourceApplicationBundleIdentifier: String?
  let createdAt: Date
  let isTextTruncated: Bool
  var isPinned: Bool

  var isImage: Bool {
    imageFileName != nil
  }

  init(
    id: UUID,
    text: String,
    sourceApplication: String?,
    sourceApplicationBundleIdentifier: String? = nil,
    createdAt: Date,
    isTextTruncated: Bool = false,
    isPinned: Bool = false
  ) {
    self.id = id
    self.text = text
    imageFileName = nil
    imagePixelWidth = nil
    imagePixelHeight = nil
    imageByteCount = nil
    self.sourceApplication = sourceApplication
    self.sourceApplicationBundleIdentifier = sourceApplicationBundleIdentifier
    self.createdAt = createdAt
    self.isTextTruncated = isTextTruncated
    self.isPinned = isPinned
  }

  init(
    id: UUID,
    imageFileName: String,
    imagePixelWidth: Int,
    imagePixelHeight: Int,
    imageByteCount: Int? = nil,
    sourceApplication: String?,
    sourceApplicationBundleIdentifier: String? = nil,
    createdAt: Date,
    isPinned: Bool = false
  ) {
    self.id = id
    text = nil
    self.imageFileName = imageFileName
    self.imagePixelWidth = imagePixelWidth
    self.imagePixelHeight = imagePixelHeight
    self.imageByteCount = imageByteCount
    self.sourceApplication = sourceApplication
    self.sourceApplicationBundleIdentifier = sourceApplicationBundleIdentifier
    self.createdAt = createdAt
    isTextTruncated = false
    self.isPinned = isPinned
  }

  func matchesSearch(_ query: String) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return true }
    let searchableValues = [
      text,
      sourceApplication,
      isImage ? "image photo" : "text",
    ].compactMap { $0 }
    return searchableValues.contains { value in
      value.range(
        of: normalizedQuery,
        options: [.caseInsensitive, .diacriticInsensitive]
      ) != nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case text
    case imageFileName
    case imagePixelWidth
    case imagePixelHeight
    case imageByteCount
    case sourceApplication
    case sourceApplicationBundleIdentifier
    case createdAt
    case isTextTruncated
    case isPinned
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    text = try container.decodeIfPresent(String.self, forKey: .text)
    imageFileName = try container.decodeIfPresent(
      String.self,
      forKey: .imageFileName
    )
    imagePixelWidth = try container.decodeIfPresent(Int.self, forKey: .imagePixelWidth)
    imagePixelHeight = try container.decodeIfPresent(Int.self, forKey: .imagePixelHeight)
    imageByteCount = try container.decodeIfPresent(Int.self, forKey: .imageByteCount)
    sourceApplication = try container.decodeIfPresent(
      String.self,
      forKey: .sourceApplication
    )
    sourceApplicationBundleIdentifier = try container.decodeIfPresent(
      String.self,
      forKey: .sourceApplicationBundleIdentifier
    )
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    isTextTruncated = try container.decodeIfPresent(
      Bool.self,
      forKey: .isTextTruncated
    ) ?? false
    isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
  }
}

@MainActor
final class ClipboardStore: NSObject, ObservableObject {
  static let preferenceKey = "clipboardHistoryEnabled"
  static let retentionPreferenceKey = "clipboardRetentionLimit"
  static let autoExpiryPreferenceKey = "clipboardAutoExpiry"
  static let excludedApplicationsPreferenceKey = "clipboardExcludedApplications"
  static let pollingInterval: TimeInterval = 1.5
  static let maximumEntryCount = 30
  static let availableRetentionLimits = [10, 30, 50, 100]
  static let maximumTextLength = 10_000
  nonisolated static let maximumImageBytes = 20_000_000
  nonisolated static let maximumImageDimension = 4_096
  nonisolated static let fallbackImageDimension = 2_048

  @Published private(set) var entries: [ClipboardEntry] = []
  @Published private(set) var isEnabled: Bool
  @Published private(set) var retentionLimit: Int
  @Published private(set) var autoExpiry: ClipboardAutoExpiry
  @Published private(set) var excludedApplications: [ClipboardExcludedApplication]

  var isPolling: Bool {
    timer?.isValid == true
  }

  private let storageURL: URL
  private let imageDirectoryURL: URL
  private let pasteboard: NSPasteboard
  private let defaults: UserDefaults
  private var lastChangeCount: Int
  private var timer: Timer?
  private var expiryTimer: Timer?
  private var imageCaptureGeneration: UInt = 0
  private let imageCache = NSCache<NSString, NSImage>()

  init(
    storageURL: URL = AppPaths.clipboardFile,
    pasteboard: NSPasteboard = .general,
    defaults: UserDefaults = .standard
  ) {
    self.storageURL = storageURL
    imageDirectoryURL = storageURL.deletingPathExtension()
      .appendingPathComponent("images", isDirectory: true)
    self.pasteboard = pasteboard
    self.defaults = defaults
    isEnabled = defaults.bool(forKey: Self.preferenceKey)
    retentionLimit = Self.normalizedRetentionLimit(
      defaults.integer(forKey: Self.retentionPreferenceKey)
    )
    autoExpiry = ClipboardAutoExpiry(
      rawValue: defaults.integer(forKey: Self.autoExpiryPreferenceKey)
    ) ?? .never
    excludedApplications = Self.loadExcludedApplications(from: defaults)
    lastChangeCount = pasteboard.changeCount
    super.init()
    load()
    let didRemoveExpiredEntries = purgeExpiredEntries(now: Date()) > 0
    sortEntries()
    let didTrimEntries = trimEntriesIfNeeded()
    if didRemoveExpiredEntries || didTrimEntries {
      persist()
    }
    scheduleExpiryTimer()
    if isEnabled {
      startPolling()
    }
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.preferenceKey)
    lastChangeCount = pasteboard.changeCount
    if enabled {
      startPolling()
    } else {
      imageCaptureGeneration &+= 1
      stopPolling()
    }
  }

  func copy(_ entry: ClipboardEntry) {
    if let image = image(for: entry) {
      pasteboard.clearContents()
      pasteboard.writeObjects([image])
    } else if let text = entry.text {
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
    } else {
      return
    }
    lastChangeCount = pasteboard.changeCount
  }

  func image(for entry: ClipboardEntry) -> NSImage? {
    guard let imageURL = imageURL(for: entry) else { return nil }
    let cacheKey = entry.id.uuidString as NSString
    if let cached = imageCache.object(forKey: cacheKey) {
      return cached
    }
    guard let image = NSImage(contentsOf: imageURL) else { return nil }
    imageCache.setObject(image, forKey: cacheKey)
    return image
  }

  func copySensitive(_ text: String) {
    pasteboard.declareTypes(
      [
        .string,
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
      ],
      owner: nil
    )
    pasteboard.setString(text, forType: .string)
    lastChangeCount = pasteboard.changeCount
  }

  func remove(_ id: UUID) {
    if let entry = entries.first(where: { $0.id == id }) {
      removeImage(for: entry)
    }
    entries.removeAll { $0.id == id }
    persist()
    scheduleExpiryTimer()
  }

  func clear() {
    imageCaptureGeneration &+= 1
    entries.removeAll()
    imageCache.removeAllObjects()
    do {
      if FileManager.default.fileExists(atPath: imageDirectoryURL.path) {
        try FileManager.default.removeItem(at: imageDirectoryURL)
      }
    } catch {
      NSLog("NotchRouter could not clear clipboard images: \(error)")
    }
    persist()
    scheduleExpiryTimer()
  }

  func setRetentionLimit(_ limit: Int) {
    let normalized = Self.normalizedRetentionLimit(limit)
    guard normalized != retentionLimit else { return }
    retentionLimit = normalized
    defaults.set(normalized, forKey: Self.retentionPreferenceKey)
    trimEntriesIfNeeded()
    persist()
  }

  func setAutoExpiry(_ expiry: ClipboardAutoExpiry) {
    guard expiry != autoExpiry else { return }
    autoExpiry = expiry
    defaults.set(expiry.rawValue, forKey: Self.autoExpiryPreferenceKey)
    if purgeExpiredEntries(now: Date()) > 0 {
      persist()
    }
    scheduleExpiryTimer()
  }

  func togglePinned(_ id: UUID) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].isPinned.toggle()
    sortEntries()
    trimEntriesIfNeeded()
    persist()
    scheduleExpiryTimer()
  }

  @discardableResult
  func removeExpiredEntries(now: Date = Date()) -> Int {
    let removedCount = purgeExpiredEntries(now: now)
    if removedCount > 0 {
      persist()
    }
    scheduleExpiryTimer()
    return removedCount
  }

  func chooseApplicationsToExclude() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.canCreateDirectories = false
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.prompt = "Exclude"
    panel.message = "Choose apps whose clipboard content NotchRouter should ignore."
    panel.begin { [weak self] response in
      guard response == .OK else { return }
      Task { @MainActor in
        for url in panel.urls {
          self?.excludeApplication(at: url)
        }
      }
    }
  }

  func excludeApplication(
    bundleIdentifier: String,
    name: String
  ) {
    let normalizedIdentifier = bundleIdentifier.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !normalizedIdentifier.isEmpty else { return }
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let application = ClipboardExcludedApplication(
      bundleIdentifier: normalizedIdentifier,
      name: normalizedName.isEmpty ? normalizedIdentifier : normalizedName
    )
    excludedApplications.removeAll { $0.bundleIdentifier == normalizedIdentifier }
    excludedApplications.append(application)
    excludedApplications.sort {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    persistExcludedApplications()
  }

  func excludeSourceApplication(for entry: ClipboardEntry) {
    guard let bundleIdentifier = entry.sourceApplicationBundleIdentifier else {
      return
    }
    excludeApplication(
      bundleIdentifier: bundleIdentifier,
      name: entry.sourceApplication ?? bundleIdentifier
    )
  }

  func removeExcludedApplication(_ bundleIdentifier: String) {
    let originalCount = excludedApplications.count
    excludedApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
    guard excludedApplications.count != originalCount else { return }
    persistExcludedApplications()
  }

  func icon(for application: ClipboardExcludedApplication) -> NSImage {
    guard
      let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: application.bundleIdentifier
      )
    else {
      return NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        ?? NSImage()
    }
    return NSWorkspace.shared.icon(forFile: url.path)
  }

  static func shouldCapture(types: [NSPasteboard.PasteboardType]) -> Bool {
    ClipboardCapturePolicy.shouldCapture(typeNames: types.map(\.rawValue))
  }

  @objc func captureIfChanged() {
    if purgeExpiredEntries(now: Date()) > 0 {
      persist()
      scheduleExpiryTimer()
    }
    guard isEnabled else {
      lastChangeCount = pasteboard.changeCount
      return
    }
    guard pasteboard.changeCount != lastChangeCount else { return }
    lastChangeCount = pasteboard.changeCount

    let source = sourceApplication()
    guard !isExcluded(bundleIdentifier: source?.bundleIdentifier) else { return }
    let types = pasteboard.types ?? []
    guard Self.shouldCapture(types: types) else { return }

    if let capturedImageData = capturedImageData() {
      addImage(capturedImageData, sourceApplication: source)
      return
    } else if let originalText = pasteboard.string(forType: .string) {
      let emptinessCheck = originalText.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard !emptinessCheck.isEmpty else {
        return
      }
      let isTextTruncated = originalText.count > Self.maximumTextLength
      let text = isTextTruncated
        ? String(originalText.prefix(Self.maximumTextLength))
        : originalText
      guard
        mostRecentEntry?.text != text
          || mostRecentEntry?.isTextTruncated != isTextTruncated
      else { return }
      entries.insert(
        ClipboardEntry(
          id: UUID(),
          text: text,
          sourceApplication: source?.name,
          sourceApplicationBundleIdentifier: source?.bundleIdentifier,
          createdAt: Date(),
          isTextTruncated: isTextTruncated
        ),
        at: 0
      )
    } else {
      return
    }

    trimEntriesIfNeeded()
    sortEntries()
    persist()
    scheduleExpiryTimer()
  }

  private func startPolling() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(
      timeInterval: Self.pollingInterval,
      target: self,
      selector: #selector(captureIfChanged),
      userInfo: nil,
      repeats: true
    )
    timer?.tolerance = 0.4
  }

  private func stopPolling() {
    timer?.invalidate()
    timer = nil
  }

  private func load() {
    do {
      let data = try Data(contentsOf: storageURL)
      let decodedEntries = try ActivityCoding.makeDecoder().decode(
        [ClipboardEntry].self,
        from: data
      )
      entries = decodedEntries.filter { entry in
        if entry.isImage {
          guard let url = imageURL(for: entry) else { return false }
          return FileManager.default.fileExists(atPath: url.path)
        }
        return entry.text?.isEmpty == false
      }
      removeOrphanedImages()
    } catch CocoaError.fileReadNoSuchFile {
      entries = []
    } catch {
      entries = []
      NSLog("NotchRouter could not read clipboard history: \(error)")
    }
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(
        at: storageURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let data = try ActivityCoding.makeEncoder(prettyPrinted: true)
        .encode(entries)
      try data.write(to: storageURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: storageURL.path
      )
    } catch {
      NSLog("NotchRouter could not persist clipboard history: \(error)")
    }
  }

  private func sourceApplication() -> ClipboardSourceApplication? {
    let frontmostApplication = NSWorkspace.shared.frontmostApplication
    guard frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
      return nil
    }
    guard
      let name = frontmostApplication?.localizedName,
      !name.isEmpty
    else { return nil }
    return ClipboardSourceApplication(
      name: name,
      bundleIdentifier: frontmostApplication?.bundleIdentifier
    )
  }

  private func capturedImageData() -> Data? {
    if let data = pasteboard.data(forType: .png), !data.isEmpty {
      return data
    }
    if let data = pasteboard.data(forType: .tiff), !data.isEmpty {
      return data
    }
    return nil
  }

  private func addImage(
    _ capturedData: Data,
    sourceApplication: ClipboardSourceApplication?
  ) {
    let id = UUID()
    let fileName = "\(id.uuidString).png"
    let fileURL = imageDirectoryURL.appendingPathComponent(fileName)
    let directoryURL = imageDirectoryURL
    let createdAt = Date()
    let generation = imageCaptureGeneration
    let existingImage: ExistingClipboardImage? = mostRecentEntry.flatMap { entry in
      guard entry.isImage,
        let byteCount = entry.imageByteCount,
        let url = imageURL(for: entry)
      else { return nil }
      return ExistingClipboardImage(url: url, byteCount: byteCount)
    }

    Task { @MainActor [weak self] in
      do {
        let persistedImage = try await Task.detached(priority: .utility) {
          try Self.encodeAndPersistImage(
            capturedData,
            existingImage: existingImage,
            imageDirectoryURL: directoryURL,
            fileURL: fileURL
          )
        }.value
        guard let persistedImage else { return }
        guard let self, generation == self.imageCaptureGeneration else {
          Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: persistedImage.fileURL)
          }
          return
        }

        self.entries.insert(
          ClipboardEntry(
            id: id,
            imageFileName: fileName,
            imagePixelWidth: persistedImage.pixelWidth,
            imagePixelHeight: persistedImage.pixelHeight,
            imageByteCount: persistedImage.data.count,
            sourceApplication: sourceApplication?.name,
            sourceApplicationBundleIdentifier: sourceApplication?.bundleIdentifier,
            createdAt: createdAt
          ),
          at: 0
        )
        if let storedImage = NSImage(data: persistedImage.data) {
          self.imageCache.setObject(storedImage, forKey: id.uuidString as NSString)
        }
        self.trimEntriesIfNeeded()
        self.sortEntries()
        self.persist()
        self.scheduleExpiryTimer()
      } catch {
        NSLog("NotchRouter could not persist clipboard image: \(error)")
      }
    }
  }

  nonisolated private static func encodeAndPersistImage(
    _ capturedData: Data,
    existingImage: ExistingClipboardImage?,
    imageDirectoryURL: URL,
    fileURL: URL
  ) throws -> PersistedClipboardImage? {
    guard let image = NSImage(data: capturedData),
      let encoded = encodedImage(image)
    else { return nil }

    if let existingImage,
      existingImage.byteCount == encoded.data.count,
      let existingData = try? Data(contentsOf: existingImage.url),
      existingData == encoded.data
    {
      return nil
    }

    try FileManager.default.createDirectory(
      at: imageDirectoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try encoded.data.write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
    return PersistedClipboardImage(
      fileURL: fileURL,
      data: encoded.data,
      pixelWidth: encoded.pixelWidth,
      pixelHeight: encoded.pixelHeight
    )
  }

  nonisolated private static func encodedImage(
    _ image: NSImage
  ) -> EncodedClipboardImage? {
    guard
      let initial = renderPNG(
        image,
        maximumDimension: Self.maximumImageDimension
      )
    else { return nil }
    if initial.data.count <= Self.maximumImageBytes {
      return initial
    }
    return renderPNG(
      image,
      maximumDimension: Self.fallbackImageDimension
    )
  }

  nonisolated private static func renderPNG(
    _ image: NSImage,
    maximumDimension: Int
  ) -> EncodedClipboardImage? {
    let sourceSize = imagePixelSize(image)
    guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

    let scale = min(
      1,
      CGFloat(maximumDimension) / max(sourceSize.width, sourceSize.height)
    )
    let pixelWidth = max(1, Int((sourceSize.width * scale).rounded()))
    let pixelHeight = max(1, Int((sourceSize.height * scale).rounded()))
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      return nil
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
      in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
      from: .zero,
      operation: .copy,
      fraction: 1
    )
    context.flushGraphics()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      return nil
    }
    return EncodedClipboardImage(
      data: data,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
  }

  nonisolated private static func imagePixelSize(_ image: NSImage) -> CGSize {
    let representationSize = image.representations.reduce(CGSize.zero) {
      current, representation in
      CGSize(
        width: max(current.width, CGFloat(representation.pixelsWide)),
        height: max(current.height, CGFloat(representation.pixelsHigh))
      )
    }
    if representationSize.width > 0, representationSize.height > 0 {
      return representationSize
    }
    return image.size
  }

  @discardableResult
  private func trimEntriesIfNeeded() -> Bool {
    let unpinnedEntries = entries
      .filter { !$0.isPinned }
      .sorted { $0.createdAt > $1.createdAt }
    guard unpinnedEntries.count > retentionLimit else { return false }
    let removedEntries = Array(unpinnedEntries.dropFirst(retentionLimit))
    let removedIDs = Set(removedEntries.map(\.id))
    for entry in removedEntries {
      removeImage(for: entry)
    }
    entries.removeAll { removedIDs.contains($0.id) }
    return true
  }

  private var mostRecentEntry: ClipboardEntry? {
    entries.max { $0.createdAt < $1.createdAt }
  }

  private func sortEntries() {
    entries.sort { left, right in
      if left.isPinned != right.isPinned {
        return left.isPinned
      }
      return left.createdAt > right.createdAt
    }
  }

  private func purgeExpiredEntries(now: Date) -> Int {
    guard let interval = autoExpiry.interval else { return 0 }
    let expiredEntries = entries.filter {
      !$0.isPinned && now.timeIntervalSince($0.createdAt) >= interval
    }
    guard !expiredEntries.isEmpty else { return 0 }
    let expiredIDs = Set(expiredEntries.map(\.id))
    for entry in expiredEntries {
      removeImage(for: entry)
    }
    entries.removeAll { expiredIDs.contains($0.id) }
    return expiredEntries.count
  }

  private func scheduleExpiryTimer() {
    expiryTimer?.invalidate()
    expiryTimer = nil
    guard let interval = autoExpiry.interval else { return }
    guard let nextExpiryDate = entries
      .filter({ !$0.isPinned })
      .map({ $0.createdAt.addingTimeInterval(interval) })
      .min()
    else { return }
    expiryTimer = Timer.scheduledTimer(
      timeInterval: max(nextExpiryDate.timeIntervalSinceNow, 0.1),
      target: self,
      selector: #selector(expireEntriesOnTimer),
      userInfo: nil,
      repeats: false
    )
  }

  @objc private func expireEntriesOnTimer() {
    removeExpiredEntries()
  }

  private func isExcluded(bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return excludedApplications.contains {
      $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
    }
  }

  private func excludeApplication(at url: URL) {
    guard
      let bundle = Bundle(url: url),
      let bundleIdentifier = bundle.bundleIdentifier
    else { return }
    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? url.deletingPathExtension().lastPathComponent
    excludeApplication(bundleIdentifier: bundleIdentifier, name: name)
  }

  private func persistExcludedApplications() {
    do {
      defaults.set(
        try JSONEncoder().encode(excludedApplications),
        forKey: Self.excludedApplicationsPreferenceKey
      )
    } catch {
      NSLog("NotchRouter could not save clipboard app exclusions: \(error)")
    }
  }

  private static func loadExcludedApplications(
    from defaults: UserDefaults
  ) -> [ClipboardExcludedApplication] {
    guard
      let data = defaults.data(forKey: excludedApplicationsPreferenceKey),
      let applications = try? JSONDecoder().decode(
        [ClipboardExcludedApplication].self,
        from: data
      )
    else { return [] }
    return applications
  }

  private func imageURL(for entry: ClipboardEntry) -> URL? {
    guard let fileName = entry.imageFileName,
      !fileName.isEmpty,
      fileName == URL(fileURLWithPath: fileName).lastPathComponent
    else { return nil }
    return imageDirectoryURL.appendingPathComponent(fileName)
  }

  private func removeImage(for entry: ClipboardEntry) {
    imageCache.removeObject(forKey: entry.id.uuidString as NSString)
    guard let url = imageURL(for: entry) else { return }
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    } catch {
      NSLog("NotchRouter could not remove clipboard image: \(error)")
    }
  }

  private func removeOrphanedImages() {
    guard
      let imageURLs = try? FileManager.default.contentsOfDirectory(
        at: imageDirectoryURL,
        includingPropertiesForKeys: nil
      )
    else { return }
    let referencedNames = Set(entries.compactMap(\.imageFileName))
    for url in imageURLs where !referencedNames.contains(url.lastPathComponent) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func normalizedRetentionLimit(_ value: Int) -> Int {
    guard value > 0 else { return maximumEntryCount }
    return min(max(value, 1), 200)
  }
}

private struct ClipboardSourceApplication: Sendable {
  let name: String
  let bundleIdentifier: String?
}

private struct ExistingClipboardImage: Sendable {
  let url: URL
  let byteCount: Int
}

private struct EncodedClipboardImage: Sendable {
  let data: Data
  let pixelWidth: Int
  let pixelHeight: Int
}

private struct PersistedClipboardImage: Sendable {
  let fileURL: URL
  let data: Data
  let pixelWidth: Int
  let pixelHeight: Int
}
