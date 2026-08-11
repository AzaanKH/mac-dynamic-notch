import Combine
import Foundation
import NotchRouterCore

struct BrowserDownloadItem: Identifiable, Equatable, Sendable {
  let id: String
  let downloadID: Int
  let browserName: String
  var filename: String
  var sourceURL: String?
  var bytesReceived: Int64
  var totalBytes: Int64
  var estimatedEndTime: Date?
  var state: BrowserDownloadState
  var isPaused: Bool
  var canResume: Bool
  var error: String?
  var updatedAt: Date

  var displayName: String {
    let component = URL(fileURLWithPath: filename).lastPathComponent
    return component.isEmpty ? "Download" : component
  }

  var progress: Double? {
    guard totalBytes > 0 else { return nil }
    return min(max(Double(bytesReceived) / Double(totalBytes), 0), 1)
  }

  var isActive: Bool {
    state == .inProgress
  }

  var sourceHost: String? {
    guard let sourceURL, let url = URL(string: sourceURL) else { return nil }
    return url.host(percentEncoded: false)
  }
}

@MainActor
final class BrowserDownloadStore: ObservableObject {
  @Published private(set) var items: [BrowserDownloadItem] = []

  var onChange: (() -> Void)?

  private struct PendingCommand {
    let browserName: String
    let command: BrowserDownloadCommand
  }

  private var pendingCommands: [PendingCommand] = []
  private var expiryTasks: [String: Task<Void, Never>] = [:]
  private let historyLimit: Int
  private let heartbeatTimeout: Duration

  init(
    historyLimit: Int = 20,
    heartbeatTimeout: Duration = .seconds(8)
  ) {
    self.historyLimit = max(historyLimit, 1)
    self.heartbeatTimeout = heartbeatTimeout
  }

  var activeDownload: BrowserDownloadItem? {
    items.first(where: \.isActive)
  }

  var activeCount: Int {
    items.count(where: \.isActive)
  }

  func ingest(_ event: BrowserDownloadEvent) throws -> BrowserDownloadBridgeResponse {
    let event = try event.validated()
    if event.kind == .disabled {
      expiryTasks.removeValue(forKey: event.browserName)?.cancel()
    }
    let didChange: Bool
    switch event.kind {
    case .heartbeat:
      didChange = false
    case .removed:
      let previousCount = items.count
      items.removeAll { item in
        item.downloadID == event.downloadID
          && item.browserName == event.browserName
      }
      didChange = items.count != previousCount
    case .update:
      didChange = apply(event)
    case .disabled:
      didChange = markActiveDownloadsInterrupted(
        from: event.browserName,
        message: "Browser download access is off."
      )
      pendingCommands.removeAll { $0.browserName == event.browserName }
    }

    if event.kind != .disabled {
      if items.contains(where: {
        $0.browserName == event.browserName && $0.isActive
      }) {
        refreshLiveness(for: event.browserName)
      } else {
        expiryTasks.removeValue(forKey: event.browserName)?.cancel()
      }
    }

    if didChange {
      sortAndTrim()
      onChange?()
    }

    let commandIndex = pendingCommands.firstIndex {
      $0.browserName == event.browserName
    }
    let command = commandIndex.map { pendingCommands.remove(at: $0).command }
    return BrowserDownloadBridgeResponse(status: "ok", command: command)
  }

  func pause(_ item: BrowserDownloadItem) {
    enqueue(.pause, for: item)
  }

  func resume(_ item: BrowserDownloadItem) {
    enqueue(.resume, for: item)
  }

  func cancel(_ item: BrowserDownloadItem) {
    enqueue(.cancel, for: item)
  }

  func reveal(_ item: BrowserDownloadItem) {
    enqueue(.reveal, for: item)
  }

  func clearHistory() {
    let previousCount = items.count
    items.removeAll { !$0.isActive }
    guard items.count != previousCount else { return }
    onChange?()
  }

  private func apply(_ event: BrowserDownloadEvent) -> Bool {
    guard let state = event.state else { return false }
    let id = Self.identifier(
      browserName: event.browserName,
      downloadID: event.downloadID
    )
    let now = Date()
    let newItem = BrowserDownloadItem(
      id: id,
      downloadID: event.downloadID,
      browserName: event.browserName,
      filename: event.filename ?? "Download",
      sourceURL: event.sourceURL,
      bytesReceived: max(event.bytesReceived ?? 0, 0),
      totalBytes: event.totalBytes ?? -1,
      estimatedEndTime: event.estimatedEndTime,
      state: state,
      isPaused: event.isPaused ?? false,
      canResume: event.canResume ?? false,
      error: event.error,
      updatedAt: now
    )

    if let index = items.firstIndex(where: { $0.id == id }) {
      var updatedItem = newItem
      if event.filename == nil {
        updatedItem.filename = items[index].filename
      }
      if event.sourceURL == nil {
        updatedItem.sourceURL = items[index].sourceURL
      }
      if event.estimatedEndTime == nil {
        updatedItem.estimatedEndTime = items[index].estimatedEndTime
      }
      guard updatedItem != items[index] else { return false }
      items[index] = updatedItem
    } else {
      items.append(newItem)
    }
    return true
  }

  private func enqueue(
    _ action: BrowserDownloadCommandKind,
    for item: BrowserDownloadItem
  ) {
    pendingCommands.removeAll {
      $0.browserName == item.browserName
        && $0.command.downloadID == item.downloadID
    }
    pendingCommands.append(
      PendingCommand(
        browserName: item.browserName,
        command: BrowserDownloadCommand(
          downloadID: item.downloadID,
          action: action
        )
      )
    )
  }

  private func sortAndTrim() {
    items.sort { first, second in
      if first.isActive != second.isActive {
        return first.isActive
      }
      return first.updatedAt > second.updatedAt
    }
    if items.count > historyLimit {
      items.removeLast(items.count - historyLimit)
    }
  }

  private func refreshLiveness(for browserName: String) {
    expiryTasks.removeValue(forKey: browserName)?.cancel()
    let timeout = heartbeatTimeout
    expiryTasks[browserName] = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard let self else { return }
      self.expiryTasks[browserName] = nil
      if self.markActiveDownloadsInterrupted(
        from: browserName,
        message: "Browser bridge disconnected."
      ) {
        self.sortAndTrim()
        self.onChange?()
      }
    }
  }

  private func markActiveDownloadsInterrupted(
    from browserName: String,
    message: String
  ) -> Bool {
    var didChange = false
    let now = Date()
    for index in items.indices
    where items[index].browserName == browserName && items[index].isActive {
      items[index].state = .interrupted
      items[index].estimatedEndTime = nil
      items[index].canResume = false
      items[index].error = message
      items[index].updatedAt = now
      didChange = true
    }
    return didChange
  }

  private static func identifier(browserName: String, downloadID: Int) -> String {
    "\(browserName):\(downloadID)"
  }
}
