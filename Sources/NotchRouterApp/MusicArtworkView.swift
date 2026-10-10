import SwiftUI

struct MusicArtworkView: View {
  let snapshot: NowPlayingSnapshot
  let size: CGFloat
  let cornerRadius: CGFloat

  @State private var image: CGImage?
  @State private var imageSource: ArtworkSource?
  @Environment(\.artworkMorphNamespace) private var morphNamespace

  init(snapshot: NowPlayingSnapshot, size: CGFloat, cornerRadius: CGFloat) {
    self.snapshot = snapshot
    self.size = size
    self.cornerRadius = cornerRadius
    // A new view (for example after the notch changes size) starts with the
    // cover already on screen instead of flashing the fallback.
    let source = snapshot.artworkSource
    _image = State(initialValue: source.flatMap(DisplayedArtworkCache.image(for:)))
    _imageSource = State(initialValue: source)
  }

  var body: some View {
    ZStack {
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .scaledToFill()
          .id(imageSource)
          .transition(.opacity)
      } else {
        fallback
          .transition(.opacity)
      }
    }
    .task(id: snapshot.artworkSource) {
      guard let source = snapshot.artworkSource else {
        withAnimation(.easeInOut(duration: 0.25)) { image = nil }
        return
      }
      guard source != imageSource || image == nil else { return }
      // Keep the previous cover until the next one is ready, then crossfade.
      let loaded = await ArtworkLoader.shared.image(for: source)
      guard !Task.isCancelled else { return }
      if let loaded { DisplayedArtworkCache.store(loaded, for: source) }
      withAnimation(.easeInOut(duration: 0.25)) {
        image = loaded
        imageSource = source
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(.white.opacity(0.09), lineWidth: 0.5)
    }
    .morphingArtwork(in: morphNamespace)
    .accessibilityLabel("\(snapshot.album) cover artwork")
  }

  private var fallback: some View {
    LinearGradient(
      colors: [.pink.opacity(0.34), .purple.opacity(0.18)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .overlay {
      Image(systemName: snapshot.source.symbolName)
        .font(.system(size: size * 0.38, weight: .semibold))
        .foregroundStyle(.pink)
    }
  }
}

/// Covers that have already been shown, readable synchronously so a newly
/// created artwork view can render its first frame with the image.
@MainActor
enum DisplayedArtworkCache {
  private static var images: [ArtworkSource: CGImage] = [:]
  private static let limit = 12

  static func image(for source: ArtworkSource) -> CGImage? {
    images[source]
  }

  static func store(_ image: CGImage, for source: ArtworkSource) {
    if images[source] == nil, images.count >= limit { images.removeAll() }
    images[source] = image
  }
}

private struct ArtworkMorphNamespaceKey: EnvironmentKey {
  static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
  /// Set by the notch root so the now-playing cover morphs between the menu
  /// bar, preview, and dashboard sizes. `nil` disables the morph.
  var artworkMorphNamespace: Namespace.ID? {
    get { self[ArtworkMorphNamespaceKey.self] }
    set { self[ArtworkMorphNamespaceKey.self] = newValue }
  }
}

private extension View {
  @ViewBuilder
  func morphingArtwork(in namespace: Namespace.ID?) -> some View {
    if let namespace {
      matchedGeometryEffect(id: "nowPlayingArtwork", in: namespace)
    } else {
      self
    }
  }
}
