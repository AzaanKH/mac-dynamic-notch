import SwiftUI

struct CompactMusicView: View {
  let snapshot: NowPlayingSnapshot
  let controller: MusicController
  let hardwareNotchWidth: CGFloat
  let hardwareNotchHeight: CGFloat
  let hasPhysicalNotch: Bool
  let isPeek: Bool
  let onSelectSection: (NotchSection) -> Void

  var body: some View {
    Group {
      if hasPhysicalNotch {
        if isPeek {
          physicalPeek
        } else {
          physicalCompact
        }
      } else {
        if isPeek {
          softwarePeek
        } else {
          softwareCompact
        }
      }
    }
  }

  private var accent: Color {
    controller.artworkPalette?.accent ?? .pink
  }

  private var physicalCompact: some View {
    HStack(spacing: 7) {
      MusicArtworkView(snapshot: snapshot, size: 19, cornerRadius: 5)
        .frame(maxWidth: .infinity, alignment: .leading)

      Color.clear
        .frame(width: max(hardwareNotchWidth - 18, 116))

      PlaybackIndicator(isPlaying: snapshot.isPlaying, tint: accent)
        .font(.caption.weight(.bold))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
  }

  private var physicalPeek: some View {
    VStack(spacing: 5) {
      HStack(spacing: 7) {
        HStack(spacing: 6) {
          Image(systemName: snapshot.source.symbolName)
            .font(.caption.weight(.semibold))
            .dashboardTint(accent)
          Text(snapshot.sourceName)
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Color.clear
          .frame(width: max(hardwareNotchWidth - 18, 116))

        PlaybackIndicator(isPlaying: snapshot.isPlaying, tint: accent)
          .font(.caption.weight(.bold))
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .frame(height: max(hardwareNotchHeight - 5, 26))

      HStack(spacing: 9) {
        MusicArtworkView(snapshot: snapshot, size: 34, cornerRadius: 8)
          .shadow(color: accent.opacity(0.45), radius: 8)
        trackLabels
        Spacer(minLength: 5)
        quickControls
      }

      SystemVolumeSlider(controller: controller.systemVolume)
        .frame(maxWidth: 190, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)

      HoverSectionNavigation(
        currentSection: .music,
        onSelect: onSelectSection
      )
    }
    .padding(.horizontal, 10)
    .padding(.top, 2)
    .padding(.bottom, 7)
  }

  private var softwareCompact: some View {
    HStack(spacing: 7) {
      MusicArtworkView(snapshot: snapshot, size: 21, cornerRadius: 6)
      Text(snapshot.title)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: 5)
      PlaybackIndicator(isPlaying: snapshot.isPlaying, tint: accent)
        .font(.caption.weight(.bold))
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
  }

  private var softwarePeek: some View {
    VStack(spacing: 5) {
      HStack(spacing: 9) {
        MusicArtworkView(snapshot: snapshot, size: 38, cornerRadius: 9)
          .shadow(color: accent.opacity(0.45), radius: 8)
        trackLabels
        Spacer(minLength: 5)
        quickControls
      }

      SystemVolumeSlider(controller: controller.systemVolume)
        .frame(maxWidth: 190, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)

      HoverSectionNavigation(
        currentSection: .music,
        onSelect: onSelectSection
      )
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
  }

  private var trackLabels: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(snapshot.title)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
      Text(snapshot.artist)
        .font(.caption)
        .dashboardSecondaryText()
        .lineLimit(1)
    }
  }

  private var quickControls: some View {
    HStack(spacing: 4) {
      Button(action: controller.previousTrack) {
        Image(systemName: "backward.fill")
      }
      .buttonStyle(NotchCircularButtonStyle(size: 32, typography: .compact))
      .accessibilityLabel("Previous track")
      .disabled(!snapshot.supportsPrevious)

      Button(action: controller.togglePlayback) {
        PlayPauseSymbol(isPlaying: snapshot.isPlaying)
      }
      .buttonStyle(NotchCircularButtonStyle(size: 36, isPrimary: true, typography: .compact))
      .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")

      Button(action: controller.nextTrack) {
        Image(systemName: "forward.fill")
      }
      .buttonStyle(NotchCircularButtonStyle(size: 32, typography: .compact))
      .accessibilityLabel("Next track")
      .disabled(!snapshot.supportsNext)
    }
  }
}
