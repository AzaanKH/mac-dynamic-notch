import CoreGraphics
import Foundation
import Testing
@testable import NotchRouterApp

private func makeImage(
  red: UInt8,
  green: UInt8,
  blue: UInt8,
  alpha: UInt8 = 255,
  size: Int = 8
) -> CGImage? {
  var bytes = [UInt8](
    repeating: 0,
    count: size * size * 4
  )
  for pixel in 0..<(size * size) {
    bytes[pixel * 4] = red
    bytes[pixel * 4 + 1] = green
    bytes[pixel * 4 + 2] = blue
    bytes[pixel * 4 + 3] = alpha
  }
  guard
    let context = CGContext(
      data: &bytes,
      width: size,
      height: size,
      bitsPerComponent: 8,
      bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else { return nil }
  return context.makeImage()
}

@Suite
struct MusicArtworkPaletteTests {
  @Test
  func vividSolidColorYieldsMatchingAccent() throws {
    let image = try #require(makeImage(red: 220, green: 40, blue: 40))
    let palette = try #require(MusicArtworkPalette.extract(from: image))

    #expect(palette.accentComponents.red > palette.accentComponents.green)
    #expect(palette.accentComponents.red > palette.accentComponents.blue)
    #expect(palette.accentComponents.red > 0.6)
  }

  @Test
  func ambientIsDarkerThanAccent() throws {
    let image = try #require(makeImage(red: 90, green: 160, blue: 220))
    let palette = try #require(MusicArtworkPalette.extract(from: image))
    let ambientLuminance = palette.ambientComponents.luminance
    #expect(ambientLuminance < palette.accentComponents.luminance)
    #expect(ambientLuminance < 0.35)
  }

  @Test
  func darkArtworkIsBrightenedForLegibility() throws {
    let image = try #require(makeImage(red: 60, green: 10, blue: 10))
    let palette = try #require(MusicArtworkPalette.extract(from: image))

    #expect(palette.accentComponents.luminance >= MusicArtworkPalette.minimumAccentLuminance - 0.05)
  }

  @Test
  func blindingArtworkIsDimmed() throws {
    let image = try #require(makeImage(red: 255, green: 255, blue: 250))
    let palette = try #require(MusicArtworkPalette.extract(from: image))

    #expect(palette.accentComponents.luminance <= MusicArtworkPalette.maximumAccentLuminance + 0.02)
  }

  @Test
  func grayscaleFallsBackToNeutralAccent() throws {
    let image = try #require(makeImage(red: 128, green: 128, blue: 128))
    let palette = try #require(MusicArtworkPalette.extract(from: image))
    let components = palette.accentComponents

    let spread = max(components.red, components.green, components.blue)
      - min(components.red, components.green, components.blue)
    #expect(spread < 0.05)
  }

  @Test
  func fullyTransparentImageYieldsNil() throws {
    let image = try #require(makeImage(red: 200, green: 30, blue: 30, alpha: 0))
    #expect(MusicArtworkPalette.extract(from: image) == nil)
  }
}
