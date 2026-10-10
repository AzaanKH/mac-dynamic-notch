import AppKit
import Observation
import Foundation
import NotchRouterCore
@preconcurrency import QuickLookUI

struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
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

struct ShelfItemPresentation {
  let url: URL?
  let icon: NSImage
}

private struct ResolvedShelfItem: Sendable {
  let url: URL?
  var refreshedBookmark: Data?
  var iconData: Data?
}

@MainActor
@Observable
final class FileShelfStore: NSObject,
  @preconcurrency QLPreviewPanelDataSource,
  QLPreviewPanelDelegate,
  NSSharingServiceDelegate
{
  private(set) var items: [ShelfItem] = []
  private(set) var lastError: String?
  private(set) var presentations: [UUID: ShelfItemPresentation] = [:]

  private let storageURL: URL
  private var previewedItemID: UUID?
  private var previewURL: URL?
  private var previewIsAccessingSecurityScope = false
  private var clearGeneration: UInt = 0
  private var pendingAddTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private lazy var historyWriter = HistoryWriter<[ShelfItem]>(storageURL: storageURL) {
    [weak self] error in
    NSLog("NotchRouter could not save the file shelf: \(error)")
    Task { @MainActor [weak self] in
      self?.lastError = "The file shelf could not be saved."
    }
  }
  private var activeAirDropURLs: [ObjectIdentifier: URL] = [:]
  private var activeAirDropServices: [ObjectIdentifier: NSSharingService] = [:]

  init(storageURL: URL = AppPaths.fileShelfFile) {
    self.storageURL = storageURL
    super.init()
    load()
  }

  var missingItemCount: Int {
    presentations.values.count { $0.url == nil }
  }

  func add(_ urls: [URL]) async {
    lastError = nil
    let generation = clearGeneration
    let operationID = UUID()
    let task = Task { [weak self] in
      let additions = await Task.detached(priority: .userInitiated) {
        var paths: Set<String> = []
        return urls.filter { $0.isFileURL }.compactMap { url -> Result<ShelfItem, Error>? in
          let url = url.standardizedFileURL
          guard paths.insert(url.path).inserted else { return nil }
          return Result { try ShelfItem(url: url) }
        }
      }.value
      guard let self else { return }
      defer { self.pendingAddTasks[operationID] = nil }
      guard generation == self.clearGeneration, !Task.isCancelled else { return }
      for addition in additions {
        switch addition {
        case .success(let item):
          guard !self.items.contains(where: { $0.path == item.path }) else { continue }
          self.items.insert(item, at: 0)
        case .failure:
          self.lastError = "Could not keep access to one of the selected files."
        }
      }
      if self.items.count > 24 { self.items.removeLast(self.items.count - 24) }
      self.presentations = self.presentations.filter { id, _ in self.items.contains { $0.id == id } }
      self.persist()
    }
    pendingAddTasks[operationID] = task
    await task.value
  }

  func remove(_ id: UUID) {
    if previewedItemID == id {
      closePreview()
    }
    presentations[id] = nil
    items.removeAll { $0.id == id }
    persist()
  }

  func clear() {
    closePreview()
    clearGeneration &+= 1
    presentations.removeAll()
    items.removeAll()
    persist()
  }

  @discardableResult
  func removeMissingItems() async -> Int {
    guard await refreshPresentation() else { return 0 }
    let missingIDs = Set(presentations.compactMap { $0.value.url == nil ? $0.key : nil })
    guard !missingIDs.isEmpty else {
      lastError = nil
      return 0
    }
    if let previewedItemID, missingIDs.contains(previewedItemID) {
      closePreview()
    }
    items.removeAll { missingIDs.contains($0.id) }
    presentations = presentations.filter { !missingIDs.contains($0.key) }
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
        await self?.add(panel.urls)
      }
    }
  }

  func open(_ item: ShelfItem) async {
    await withResolvedURL(for: item) { url in
      NSWorkspace.shared.open(url)
    }
  }

  func reveal(_ item: ShelfItem) async {
    await withResolvedURL(for: item) { url in
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  func airDrop(_ item: ShelfItem) async {
    guard let url = await resolvedURL(for: item) else {
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

  func quickLook(_ item: ShelfItem) async {
    guard let url = await resolvedURL(for: item) else {
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

  /// Refresh once when the shelf appears or its contents change, never from a view getter.
  @discardableResult
  func refreshPresentation() async -> Bool {
    let snapshot = items
    let resolved = await Task.detached(priority: .utility) {
      snapshot.map { item in
        var result = Self.resolve(item)
        result.iconData = Self.iconData(for: result.url ?? URL(fileURLWithPath: item.path))
        return result
      }
    }.value
    guard !Task.isCancelled, snapshot == items else { return false }
    var updatedItems = items
    var updatedPresentations: [UUID: ShelfItemPresentation] = [:]
    for (index, result) in resolved.enumerated() {
      let item = snapshot[index]
      if let bookmark = result.refreshedBookmark {
        updatedItems[index].bookmark = bookmark
      }
      updatedPresentations[item.id] = ShelfItemPresentation(
        url: result.url,
        icon: result.iconData.flatMap(NSImage.init(data:))
          ?? NSImage(systemSymbolName: item.isDirectory ? "folder" : "doc", accessibilityDescription: nil)!
      )
    }
    presentations = updatedPresentations
    if updatedItems != items {
      items = updatedItems
      persist()
    }
    return true
  }

  func resolvedURL(for item: ShelfItem) async -> URL? {
    let result = await Task.detached(priority: .userInitiated) {
      Self.resolve(item)
    }.value
    guard !Task.isCancelled, let index = items.firstIndex(where: { $0.id == item.id }) else {
      return nil
    }
    if let bookmark = result.refreshedBookmark, items[index].bookmark == item.bookmark {
      items[index].bookmark = bookmark
      persist()
    }
    return result.url
  }

  nonisolated private static func iconData(for url: URL) -> Data? {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
    guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
      let context = CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    guard let thumbnail = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:])
  }

  nonisolated private static func resolve(_ item: ShelfItem) -> ResolvedShelfItem {
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: item.bookmark,
        options: [.withSecurityScope, .withoutUI, .withoutMounting],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      let didAccess = url.startAccessingSecurityScopedResource()
      defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
      guard FileManager.default.fileExists(atPath: url.path) else {
        return ResolvedShelfItem(url: nil)
      }
      var result = ResolvedShelfItem(url: url)
      if isStale {
        result.refreshedBookmark = try url.bookmarkData(
          options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
          includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
          relativeTo: nil
        )
      }
      return result
    } catch {
      let fallback = URL(fileURLWithPath: item.path)
      return ResolvedShelfItem(
        url: FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
      )
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
  ) async {
    guard let url = await resolvedURL(for: item) else {
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
    historyWriter.submit(items)
  }

  func flushPersistence() async {
    let additions = Array(pendingAddTasks.values)
    for task in additions { await task.value }
    await historyWriter.flush()
  }
}
