import CoreGraphics
import Foundation
import ImageIO
import NotchRouterCore
import Testing
import UniformTypeIdentifiers
@testable import NotchRouterApp

private final class ArtworkFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.path
    let headers = path == "/declared" ? ["Content-Length": "1000000000"] : [:]
    let status = path == "/redirect" ? 302 : 200
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
    let count = path == "/small" ? 100 : 8192
    client?.urlProtocol(self, didLoad: Data(repeating: 1, count: count))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Test
func artworkRejectsUnknownDestinationsAndBoundsDeclaredAndActualBodies() async throws {
  for url in ["http://i.scdn.co/image", "https://127.0.0.1/a", "https://i.scdn.co.attacker.test/a", "https://user:pass@i.scdn.co/a", "https://i.scdn.co:8443/a", "file:///tmp/image"] {
    #expect(!ArtworkLoader.allowsRemoteURL(URL(string: url)!))
  }
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [ArtworkFixtureProtocol.self]
  let small = try await ArtworkLoader.download(url: URL(string: "https://i.scdn.co/small")!, maxBytes: 1024, configuration: config)
  #expect(small.count == 100)
  for route in ["declared", "streamed", "redirect"] {
    do {
      _ = try await ArtworkLoader.download(url: URL(string: "https://i.scdn.co/\(route)")!, maxBytes: 1024, configuration: config)
      Issue.record("Expected \(route) response to be rejected")
    } catch {}
  }
}

private func png(width: Int, height: Int) throws -> Data {
  let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  let image = try #require(context.makeImage())
  let data = NSMutableData()
  let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  return data as Data
}

@Test
func artworkDecoderBoundsBrowserDimensionsAndMakesSmallNativeThumbnails() throws {
  let large = try png(width: 512, height: 512)
  #expect(ArtworkLoader.decode(large, browserThumbnail: true) == nil)
  let native = try #require(ArtworkLoader.decode(large))
  #expect(native.width <= 256 && native.height <= 256)
  #expect(ArtworkLoader.decode(Data(repeating: 0, count: 32769), browserThumbnail: true) == nil)
  #expect(ArtworkLoader.decode(Data("not an image".utf8)) == nil)
  let small = try png(width: 32, height: 32)
  #expect(ArtworkLoader.decode(small, browserThumbnail: true) != nil)
}

@MainActor
@Test
func browserArtworkURLsNeverReachNativeLoaderAndLegacyMediaStillWorks() async throws {
  let suite = "ArtworkSecurity-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let controller = MusicController(defaults: defaults)
  for url in ["http://127.0.0.1/private", "https://i.scdn.co/image"] {
    _ = try controller.ingestBrowserMedia(BrowserMediaEvent(kind: .update, sessionID: "test", browserName: "Browser", title: "Legacy track", artworkURL: URL(string: url), isPlaying: true))
    #expect(controller.nowPlaying?.artworkSource == nil)
    #expect(controller.nowPlaying?.artworkURL == nil)
    #expect(controller.nowPlaying?.title == "Legacy track")
  }
  let data = try png(width: 32, height: 32)
  _ = try controller.ingestBrowserMedia(BrowserMediaEvent(kind: .update, sessionID: "test", browserName: "Browser", title: "Thumbnail", artworkData: data))
  #expect(controller.nowPlaying?.artworkSource == .browser(data))
  let image = await ArtworkLoader.shared.image(for: .browser(data))
  #expect(image != nil)
}

private actor GatedArtworkFetch {
  private(set) var calls = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func fetch() async -> CGImage? {
    calls += 1
    await withCheckedContinuation { waiters.append($0) }
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    return context?.makeImage()
  }

  func release() {
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}

@Test
func concurrentArtworkRequestsShareOneFetchAndSurviveCancellation() async throws {
  let gate = GatedArtworkFetch()
  let loader = ArtworkLoader(fetch: { _ in await gate.fetch() })
  let source = ArtworkSource.spotify(URL(string: "https://i.scdn.co/shared")!)

  // The first request starts the shared load and is then cancelled; the
  // second joins it while the fetch is still blocked.
  let owner = Task { await loader.image(for: source) }
  let ownerStarted = await waitUntil { await gate.calls == 1 }
  let joined = Task { await loader.image(for: source) }
  let didJoin = await waitUntil { await loader.joinedRequests == 1 }
  guard ownerStarted, didJoin else {
    Issue.record("The second request did not join the pending load")
    await gate.release()
    owner.cancel()
    joined.cancel()
    return
  }
  owner.cancel()
  await gate.release()

  #expect(await joined.value != nil)
  #expect(await owner.value != nil, "Cancelling the owner does not cancel the transfer")
  #expect(await gate.calls == 1)
  // The completed cover is cached for later consumers.
  #expect(await loader.image(for: source) != nil)
  #expect(await gate.calls == 1)
}
