import AppKit
import Combine
import Foundation
import NotchRouterCore
@preconcurrency import QuickLookUI

struct ShelfItem: Codable, Identifiable, Equatable {
  let id: UUID
  var name: String
  var path: String
  var bookmark: Data
  var isDirectory: Bool
  var addedAt: Date

  init(url: URL) throws {
    let values = try? url.resourceValues(forKeys: [.nameKey, .isDirectoryKey])
    id = UUID()
    name = values?.name ?? url.lastPathComponent
    path = url.path
    isDirectory = values?.isDirectory ?? false
    addedAt = Date()

    do {
      bookmark = try url.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
        relativeTo: nil
      )
    } catch {
      bookmark = try url.bookmarkData(
        includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
        relativeTo: nil
      )
    }
  }
}

@MainActor
final class FileShelfStore: NSObject, ObservableObject,
  @preconcurrency QLPreviewPanelDataSource,
  QLPreviewPanelDelegate,
  NSSharingServiceDelegate
{
  @Published private(set) var items: [ShelfItem] = []
  @Published private(set) var lastError: String?

  private let storageURL: URL
  private var previewedItemID: UUID?
  private var previewURL: URL?
  private var previewIsAccessingSecurityScope = false
  private var resolvedURLCache: [UUID: URL] = [:]
  private var activeAirDropURLs: [ObjectIdentifier: URL] = [:]
  private var activeAirDropServices: [ObjectIdentifier: NSSharingService] = [:]

  init(storageURL: URL = AppPaths.fileShelfFile) {
    self.storageURL = storageURL
    super.init()
    load()
  }

  var missingItemCount: Int {
    items.count(where: { resolvedURL(for: $0) == nil })
  }

  func add(_ urls: [URL]) {
    lastError = nil
    resolvedURLCache.removeAll()

    for url in urls {
      guard url.isFileURL else { continue }
      let standardizedPath = url.standardizedFileURL.path
      guard !items.contains(where: { $0.path == standardizedPath }) else {
        continue
      }

      do {
        items.insert(try ShelfItem(url: url.standardizedFileURL), at: 0)
      } catch {
        lastError = "Could not keep access to \(url.lastPathComponent)."
      }
    }

    if items.count > 24 {
      items.removeLast(items.count - 24)
    }
    persist()
  }

  func remove(_ id: UUID) {
    if previewedItemID == id {
      closePreview()
    }
    resolvedURLCache[id] = nil
    items.removeAll { $0.id == id }
    persist()
  }

  func clear() {
    closePreview()
    resolvedURLCache.removeAll()
    items.removeAll()
    persist()
  }

  @discardableResult
  func removeMissingItems() -> Int {
    resolvedURLCache.removeAll()
    let missingIDs = Set(
      items.filter { resolvedURL(for: $0) == nil }.map(\.id)
    )
    guard !missingIDs.isEmpty else {
      lastError = nil
      return 0
    }
    if let previewedItemID, missingIDs.contains(previewedItemID) {
      closePreview()
    }
    items.removeAll { missingIDs.contains($0.id) }
    lastError = nil
    persist()
    return missingIDs.count
  }

  func chooseFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.prompt = "Add to Shelf"
    panel.message = "Choose files or folders to keep in the notch shelf."
    panel.begin { [weak self] response in
      guard response == .OK else { return }
      Task { @MainActor in
        self?.add(panel.urls)
      }
    }
  }

  func open(_ item: ShelfItem) {
    withResolvedURL(for: item) { url in
      NSWorkspace.shared.open(url)
    }
  }

  func reveal(_ item: ShelfItem) {
    withResolvedURL(for: item) { url in
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  func airDrop(_ item: ShelfItem) {
    guard let url = resolvedURL(for: item) else {
      lastError = "\(item.name) is no longer available."
      return
    }
    guard let service = NSSharingService(named: .sendViaAirDrop) else {
      lastError = "AirDrop is unavailable on this Mac."
      return
    }

    let identifier = ObjectIdentifier(service)
    if url.startAccessingSecurityScopedResource() {
      activeAirDropURLs[identifier] = url
    }
    activeAirDropServices[identifier] = service
    service.delegate = self
    lastError = nil
    service.perform(withItems: [url])
  }

  func quickLook(_ item: ShelfItem) {
    guard let url = resolvedURL(for: item) else {
      lastError = "\(item.name) is no longer available."
      return
    }
    guard let panel = QLPreviewPanel.shared() else {
      lastError = "Quick Look is unavailable right now."
      return
    }

    endPreviewAccess()
    previewedItemID = item.id
    previewURL = url
    previewIsAccessingSecurityScope = url.startAccessingSecurityScopedResource()
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    panel.currentPreviewItemIndex = 0
    panel.makeKeyAndOrderFront(nil)
    lastError = nil
  }

  func resolvedURL(for item: ShelfItem) -> URL? {
    if let cachedURL = resolvedURLCache[item.id] {
      guard FileManager.default.fileExists(atPath: cachedURL.path) else {
        resolvedURLCache[item.id] = nil
        return nil
      }
      return cachedURL
    }

    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: item.bookmark,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }

      if isStale {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
          if didAccess {
            url.stopAccessingSecurityScopedResource()
          }
        }
        guard
          let refreshedBookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
          ),
          let index = items.firstIndex(where: { $0.id == item.id })
        else { return nil }
        items[index].bookmark = refreshedBookmark
        persist()
      }

      resolvedURLCache[item.id] = url
      return url
    } catch {
      let fallback = URL(fileURLWithPath: item.path)
      guard FileManager.default.fileExists(atPath: fallback.path) else {
        return nil
      }
      resolvedURLCache[item.id] = fallback
      return fallback
    }
  }

  func sharingService(
    _ sharingService: NSSharingService,
    didShareItems items: [Any]
  ) {
    finishAirDrop(using: sharingService)
  }

  func sharingService(
    _ sharingService: NSSharingService,
    didFailToShareItems items: [Any],
    error: any Error
  ) {
    finishAirDrop(using: sharingService)
  }

  func icon(for item: ShelfItem) -> NSImage {
    NSWorkspace.shared.icon(forFile: item.path)
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    previewURL == nil ? 0 : 1
  }

  func previewPanel(
    _ panel: QLPreviewPanel!,
    previewItemAt index: Int
  ) -> (any QLPreviewItem)! {
    previewURL as NSURL?
  }

  func previewPanelWillClose(_ panel: QLPreviewPanel!) {
    endPreviewAccess()
  }

  private func withResolvedURL(
    for item: ShelfItem,
    action: (URL) -> Void
  ) {
    guard let url = resolvedURL(for: item) else {
      lastError = "\(item.name) is no longer available."
      return
    }

    let didAccess = url.startAccessingSecurityScopedResource()
    action(url)
    if didAccess {
      url.stopAccessingSecurityScopedResource()
    }
  }

  private func closePreview() {
    if previewURL != nil, let panel = QLPreviewPanel.shared() {
      panel.orderOut(nil)
    }
    endPreviewAccess()
  }

  private func finishAirDrop(using service: NSSharingService) {
    let identifier = ObjectIdentifier(service)
    activeAirDropURLs.removeValue(forKey: identifier)?
      .stopAccessingSecurityScopedResource()
    activeAirDropServices[identifier] = nil
  }

  private func endPreviewAccess() {
    if previewIsAccessingSecurityScope {
      previewURL?.stopAccessingSecurityScopedResource()
    }
    previewIsAccessingSecurityScope = false
    previewedItemID = nil
    previewURL = nil
  }

  private func load() {
    resolvedURLCache.removeAll()
    do {
      let data = try Data(contentsOf: storageURL)
      items = try ActivityCoding.makeDecoder().decode(
        [ShelfItem].self,
        from: data
      )
    } catch CocoaError.fileReadNoSuchFile {
      items = []
    } catch {
      items = []
      lastError = "The saved file shelf could not be read."
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
        .encode(items)
      try data.write(to: storageURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: storageURL.path
      )
    } catch {
      lastError = "The file shelf could not be saved."
    }
  }
}
