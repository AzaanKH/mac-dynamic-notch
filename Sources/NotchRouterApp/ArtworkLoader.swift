import CoreGraphics
import Foundation
import ImageIO

/// Browser artwork is transferred as bytes. Only the native Spotify integration uses a URL.
enum ArtworkSource: Hashable, Sendable {
  case browser(Data)
  case spotify(URL)
}

actor ArtworkLoader {
  static let shared = ArtworkLoader()
  static let maximumDownloadBytes = 8_000_000
  static let maximumBrowserBytes = 32_768
  static let maximumPixels = 16_000_000
  private var cache: [ArtworkSource: CGImage] = [:]

  func image(for source: ArtworkSource) async -> CGImage? {
    if let image = cache[source] { return image }
    let data: Data?
    switch source {
    case .browser(let bytes): data = bytes.count <= Self.maximumBrowserBytes ? bytes : nil
    case .spotify(let url): data = try? await Self.download(url: url)
    }
    guard let data, !Task.isCancelled,
      let image = Self.decode(data, browserThumbnail: {
        if case .browser = source { return true }; return false
      }())
    else { return nil }
    if cache.count >= 12 { cache.removeAll() }
    cache[source] = image
    return image
  }

  nonisolated static func allowsRemoteURL(_ url: URL) -> Bool {
    // Exact HTTPS hosts controlled by Spotify. Never use this path for browser metadata.
    let hosts: Set<String> = ["i.scdn.co", "mosaic.scdn.co", "image-cdn-ak.spotifycdn.com"]
    return url.scheme?.lowercased() == "https" && hosts.contains(url.host?.lowercased() ?? "")
      && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
  }

  nonisolated static func download(
    url: URL, maxBytes: Int = maximumDownloadBytes,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Data {
    guard allowsRemoteURL(url), maxBytes > 0 else { throw ArtworkError.invalidURL }
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    let transfer = ArtworkTransfer(url: url, maxBytes: maxBytes, configuration: configuration)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await transfer.run()
    } onCancel: { transfer.cancel() }
  }

  nonisolated static func decode(_ data: Data, browserThumbnail: Bool = false) -> CGImage? {
    guard data.count <= (browserThumbnail ? maximumBrowserBytes : maximumDownloadBytes),
      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= maximumPixels / height,
      !browserThumbnail || (width <= 256 && height <= 256)
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 256,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary)
  }
}

enum ArtworkError: Error { case invalidURL, invalidResponse, tooLarge }

/// The serial delegate queue and lock cap accumulated bytes before any image decoding.
private final class ArtworkTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let url: URL
  private let maxBytes: Int
  private let configuration: URLSessionConfiguration
  private var continuation: CheckedContinuation<Data, Error>?
  private var session: URLSession?
  private var data = Data()
  private var finished = false

  init(url: URL, maxBytes: Int, configuration: URLSessionConfiguration) {
    self.url = url; self.maxBytes = maxBytes; self.configuration = configuration
  }

  func run() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
      self.continuation = continuation
      let queue = OperationQueue()
      queue.maxConcurrentOperationCount = 1
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
      self.session = session
      let task = session.dataTask(with: url)
      lock.unlock()
      task.resume()
    }
  }

  func cancel() { finish(.failure(CancellationError())) }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      completionHandler(.cancel); finish(.failure(ArtworkError.invalidResponse)); return
    }
    guard response.expectedContentLength <= maxBytes else {
      completionHandler(.cancel); finish(.failure(ArtworkError.tooLarge)); return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    guard chunk.count <= maxBytes - data.count else {
      lock.unlock(); finish(.failure(ArtworkError.tooLarge)); return
    }
    data.append(chunk)
    lock.unlock()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { finish(.failure(error)) }
    else { finish(.success(lock.withLock { data })) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }

  private func finish(_ result: Result<Data, Error>) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    let continuation = continuation
    self.continuation = nil
    let session = session
    self.session = nil
    data = Data()
    lock.unlock()
    session?.invalidateAndCancel()
    continuation?.resume(with: result)
  }
}
