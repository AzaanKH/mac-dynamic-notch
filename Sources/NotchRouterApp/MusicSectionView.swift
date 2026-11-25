import Foundation
import SwiftUI

struct MusicSectionView: View {
  let controller: MusicController

  var body: some View {
    Group {
      if let snapshot = controller.nowPlaying {
        nowPlaying(snapshot)
      } else if !controller.isEnabled {
        onboarding
      } else {
        noMusic
      }
    }
    .padding(.horizontal, 15)
    .padding(.bottom, 10)
  }

  private var onboarding: some View {
    VStack(spacing: 10) {
      Image(systemName: "music.note.house")
        .font(.system(size: 28, weight: .light))
        .dashboardTint(.pink)
      Text("Connect your music apps")
        .font(.headline)
      Text(
        "Enable Apple Music and Spotify here, or install the opt-in browser bridge from Settings → Integrations."
      )
      .font(.callout)
      .dashboardSecondaryText()
      .multilineTextAlignment(.center)
      .frame(maxWidth: 340)
      Button("Enable Music Controls") {
        controller.setEnabled(true)
      }
      .buttonStyle(NotchAccentButtonStyle(tint: .pink))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var accent: Color {
    controller.artworkPalette?.accent ?? .pink
  }

  private func nowPlaying(_ snapshot: NowPlayingSnapshot) -> some View {
    VStack(spacing: 15) {
      HStack(spacing: 13) {
        MusicArtworkView(
          snapshot: snapshot,
          size: 62,
          cornerRadius: 15
        )

        VStack(alignment: .leading, spacing: 4) {
          Text(snapshot.title)
            .font(.title3.weight(.bold))
            .lineLimit(1)
          Text(snapshot.artist)
            .font(.body.weight(.medium))
            .dashboardSecondaryText()
            .lineLimit(1)
          if !snapshot.album.isEmpty && snapshot.album != snapshot.artist {
            Text(snapshot.album)
              .font(.caption)
              .dashboardTertiaryText()
              .lineLimit(1)
          }
        }
        Spacer()
      }

      if snapshot.duration > 0 {
        MusicTimelineView(snapshot: snapshot, tint: accent, onSeek: controller.seek)
          .id(snapshot.identity)
      } else {
        Label(snapshot.isPlaying ? "Live playback" : "Paused", systemImage: "dot.radiowaves.left.and.right")
          .font(.caption)
          .dashboardSecondaryText()
      }

      HStack(spacing: 14) {
        Button { controller.skip(by: -15) } label: {
          Image(systemName: "gobackward.15")
        }
        .buttonStyle(NotchCircularButtonStyle(size: 30))
        .disabled(!snapshot.canSeek)
        .accessibilityLabel("Skip back 15 seconds")
        .help("Skip back 15 seconds")

        Button(action: controller.previousTrack) {
          Image(systemName: "backward.fill")
        }
        .buttonStyle(NotchCircularButtonStyle(size: 34))
        .disabled(!snapshot.supportsPrevious)
        .accessibilityLabel("Previous track")
        .help("Previous track")

        Button(action: controller.togglePlayback) {
          PlayPauseSymbol(isPlaying: snapshot.isPlaying)
        }
        .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")
        .help(snapshot.isPlaying ? "Pause" : "Play")
        .buttonStyle(NotchCircularButtonStyle(size: 46, isPrimary: true))
        .shadow(
          color: accent.opacity(snapshot.isPlaying ? 0.55 : 0.15),
          radius: snapshot.isPlaying ? 12 : 5
        )

        Button(action: controller.nextTrack) {
          Image(systemName: "forward.fill")
        }
        .buttonStyle(NotchCircularButtonStyle(size: 34))
        .disabled(!snapshot.supportsNext)
        .accessibilityLabel("Next track")
        .help("Next track")

        Button { controller.skip(by: 15) } label: {
          Image(systemName: "goforward.15")
        }
        .buttonStyle(NotchCircularButtonStyle(size: 30))
        .disabled(!snapshot.canSeek)
        .accessibilityLabel("Skip forward 15 seconds")
        .help("Skip forward 15 seconds")
      }

      SystemVolumeSlider(
        controller: controller.systemVolume,
        showsPercentage: true
      )
      .frame(maxWidth: 280)

      if let message = controller.permissionMessage {
        Text(message)
          .font(.caption)
          .dashboardTint(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button {
          controller.openSource(snapshot.source)
        } label: {
          Label(snapshot.sourceName, systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(NotchSubtleButtonStyle())
        .help("Open \(snapshot.sourceName)")
        Spacer()
        playerOptions(snapshot)
        Menu {
          Button("Open \(snapshot.sourceName)") {
            controller.openSource(snapshot.source)
          }
          if controller.isEnabled {
            Button("Disable Apple Music & Spotify") {
              controller.setEnabled(false)
            }
          }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Playback options")
      }
    }
    .padding(14)
    .dashboardSurface(cornerRadius: 16, normalOpacity: 0.045)
  }

  /// Shuffle, repeat, and favorite appear only when the player reports them
  /// (Apple Music). An active option takes the artwork accent.
  @ViewBuilder
  private func playerOptions(_ snapshot: NowPlayingSnapshot) -> some View {
    HStack(spacing: 6) {
      if let shuffle = snapshot.shuffleEnabled {
        optionButton(
          symbol: "shuffle", isOn: shuffle, label: "Shuffle",
          action: controller.toggleShuffle
        )
      }
      if let mode = snapshot.repeatMode {
        optionButton(
          symbol: mode == .one ? "repeat.1" : "repeat", isOn: mode != .off,
          label: "Repeat", value: mode == .one ? "One" : mode == .all ? "All" : "Off",
          action: controller.cycleRepeat
        )
      }
      if let favorite = snapshot.isFavorite {
        optionButton(
          symbol: favorite ? "star.fill" : "star", isOn: favorite, label: "Favorite",
          action: controller.toggleFavorite
        )
      }
    }
  }

  private func optionButton(
    symbol: String,
    isOn: Bool,
    label: String,
    value: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .foregroundStyle(isOn ? accent : Color.white.opacity(0.7))
    }
    .buttonStyle(NotchCircularButtonStyle(size: 26))
    .accessibilityLabel(label)
    .accessibilityValue(value ?? (isOn ? "On" : "Off"))
    .help(value.map { "\(label): \($0)" } ?? label)
  }

  private var noMusic: some View {
    VStack(spacing: 10) {
      Image(systemName: "music.note")
        .font(.system(size: 27, weight: .light))
        .dashboardSecondaryText()

      if let message = controller.permissionMessage {
        Text(message)
          .font(.callout)
          .dashboardTint(.orange)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 380)
      } else {
        Text("Nothing playing")
          .font(.headline)
        Text("Start Apple Music, Spotify, or media in a connected browser.")
          .font(.callout)
          .dashboardSecondaryText()
      }

      HStack(spacing: 7) {
        ForEach(MusicSource.nativeCases, id: \.rawValue) { source in
          Button("Open \(source.displayName)") {
            controller.openSource(source)
          }
          .buttonStyle(NotchSubtleButtonStyle())
        }
        Button("Retry") {
          controller.refresh()
        }
        .buttonStyle(NotchSubtleButtonStyle())
      }

      Button("Disable Music Controls") {
        controller.setEnabled(false)
      }
      .buttonStyle(NotchSubtleButtonStyle())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

}
