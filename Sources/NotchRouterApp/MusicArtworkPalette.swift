import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

struct MusicArtworkPalette: Equatable, Sendable {
  struct Components: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var luminance: Double {
      0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
  }

  let accent: Color
  let ambient: Color
  let accentComponents: Components
  let ambientComponents: Components

  static let minimumAccentLuminance = 0.34
  static let maximumAccentLuminance = 0.88
  static let ambientBrightnessScale = 0.42

  static func load(source: ArtworkSource) async -> MusicArtworkPalette? {
    guard let image = await ArtworkLoader.shared.image(for: source) else { return nil }
    return extract(from: image)
  }

  static func extract(from image: CGImage) -> MusicArtworkPalette? {
    let sampleSize = 32
    guard
      let context = CGContext(
        data: nil,
        width: sampleSize,
        height: sampleSize,
        bitsPerComponent: 8,
        bytesPerRow: sampleSize * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    context.interpolationQuality = .medium
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize)
    )
    guard let buffer = context.data else { return nil }
    let pixels = buffer.bindMemory(
      to: UInt8.self,
      capacity: sampleSize * sampleSize * 4
    )

    var totalRed = 0.0
    var totalGreen = 0.0
    var totalBlue = 0.0
    var totalCount = 0.0
    var vividRed = 0.0
    var vividGreen = 0.0
    var vividBlue = 0.0
    var vividWeight = 0.0

    for index in 0..<(sampleSize * sampleSize) {
      let offset = index * 4
      let alpha = Double(pixels[offset + 3])
      guard alpha >= 32 else { continue }
      let alphaScale = alpha / 255
      let red = Double(pixels[offset]) / alphaScale
      let green = Double(pixels[offset + 1]) / alphaScale
      let blue = Double(pixels[offset + 2]) / alphaScale
      let clampedRed = min(red, 255)
      let clampedGreen = min(green, 255)
      let clampedBlue = min(blue, 255)

      totalRed += clampedRed
      totalGreen += clampedGreen
      totalBlue += clampedBlue
      totalCount += 1

      let spread = max(clampedRed, clampedGreen, clampedBlue)
        - min(clampedRed, clampedGreen, clampedBlue)
      let weight = min(max((spread - 20) / 100, 0), 1)
      vividRed += clampedRed * weight
      vividGreen += clampedGreen * weight
      vividBlue += clampedBlue * weight
      vividWeight += weight
    }

    guard totalCount > 0 else { return nil }

    let average = Components(
      red: totalRed / totalCount / 255,
      green: totalGreen / totalCount / 255,
      blue: totalBlue / totalCount / 255
    )
    var candidate = average
    if vividWeight > totalCount * 0.05 {
      let vivid = Components(
        red: vividRed / vividWeight / 255,
        green: vividGreen / vividWeight / 255,
        blue: vividBlue / vividWeight / 255
      )
      if vivid.luminance >= average.luminance - 0.08 {
        candidate = vivid
      }
    }

    var accentComponents = normalized(candidate)
    if accentComponents.luminance < Self.minimumAccentLuminance {
      let scale = Self.minimumAccentLuminance / max(accentComponents.luminance, 0.01)
      accentComponents = Components(
        red: min(accentComponents.red * scale, 1),
        green: min(accentComponents.green * scale, 1),
        blue: min(accentComponents.blue * scale, 1)
      )
    } else if accentComponents.luminance > Self.maximumAccentLuminance {
      let scale = Self.maximumAccentLuminance / accentComponents.luminance
      accentComponents = Components(
        red: accentComponents.red * scale,
        green: accentComponents.green * scale,
        blue: accentComponents.blue * scale
      )
    }

    let ambientComponents = Components(
      red: accentComponents.red * Self.ambientBrightnessScale,
      green: accentComponents.green * Self.ambientBrightnessScale,
      blue: accentComponents.blue * Self.ambientBrightnessScale
    )

    return MusicArtworkPalette(
      accent: color(from: accentComponents),
      ambient: color(from: ambientComponents),
      accentComponents: accentComponents,
      ambientComponents: ambientComponents
    )
  }

  private static func normalized(_ components: Components) -> Components {
    Components(
      red: min(max(components.red, 0), 1),
      green: min(max(components.green, 0), 1),
      blue: min(max(components.blue, 0), 1)
    )
  }

  private static func color(from components: Components) -> Color {
    Color(
      red: components.red,
      green: components.green,
      blue: components.blue
    )
  }
}
