import SwiftUI

struct MusicArtworkView: View {
  let snapshot: NowPlayingSnapshot
  let size: CGFloat
  let cornerRadius: CGFloat

  var body: some View {
    Group {
      if let artworkURL = snapshot.artworkURL {
        AsyncImage(
          url: artworkURL,
          transaction: Transaction(animation: .easeOut(duration: 0.2))
        ) { phase in
          switch phase {
          case .success(let image):
            image
              .resizable()
              .scaledToFill()
          case .empty:
            fallback
              .overlay {
                ProgressView()
                  .controlSize(.mini)
                  .tint(.white.opacity(0.65))
              }
          case .failure:
            fallback
          @unknown default:
            fallback
          }
        }
      } else {
        fallback
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(.white.opacity(0.09), lineWidth: 0.5)
    }
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
