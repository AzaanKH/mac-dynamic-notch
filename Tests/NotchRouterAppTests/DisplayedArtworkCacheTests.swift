import CoreGraphics
import Foundation
import Testing

@testable import NotchRouterApp

private func solidImage() throws -> CGImage {
  let context = try #require(
    CGContext(
      data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  return try #require(context.makeImage())
}

@MainActor
@Test
func displayedArtworkIsAvailableSynchronouslyAndBounded() throws {
  let image = try solidImage()
  let sources = (0..<13).map { ArtworkSource.browser(Data("cover-\(UUID())-\($0)".utf8)) }

  #expect(DisplayedArtworkCache.image(for: sources[0]) == nil)
  DisplayedArtworkCache.store(image, for: sources[0])
  #expect(DisplayedArtworkCache.image(for: sources[0]) === image)

  // Filling past the limit drops older covers instead of growing forever.
  for source in sources.dropFirst() {
    DisplayedArtworkCache.store(image, for: source)
  }
  #expect(DisplayedArtworkCache.image(for: sources[0]) == nil)
  #expect(DisplayedArtworkCache.image(for: sources[12]) === image)
}
