import Foundation
import SwiftUI

struct MusicSectionView: View {
  @ObservedObject var controller: MusicController

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
      .focusable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
          Text(snapshot.album)
            .font(.caption)
            .dashboardTertiaryText()
            .lineLimit(1)
        }
        Spacer()
      }

      if snapshot.duration > 0 {
        VStack(spacing: 5) {
          ProgressView(
            value: min(snapshot.position, snapshot.duration),
            total: snapshot.duration
          )
          .progressViewStyle(.linear)
          .tint(.pink)
          HStack {
            Text(formatTime(snapshot.position))
            Spacer()
            Text(formatTime(snapshot.duration))
          }
          .font(.caption.monospacedDigit())
          .dashboardTertiaryText()
        }
      }

      HStack(spacing: 14) {
        Button(action: controller.previousTrack) {
          Image(systemName: "backward.fill")
        }
        .buttonStyle(NotchCircularButtonStyle(size: 34))
        .focusable()
        .disabled(!snapshot.supportsPrevious)

        Button(action: controller.togglePlayback) {
          Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(NotchCircularButtonStyle(size: 46, isPrimary: true))
        .focusable()

        Button(action: controller.nextTrack) {
          Image(systemName: "forward.fill")
        }
        .buttonStyle(NotchCircularButtonStyle(size: 34))
        .focusable()
        .disabled(!snapshot.supportsNext)
      }

      SystemVolumeSlider(
        controller: controller.systemVolume,
        showsPercentage: true
      )
      .frame(maxWidth: 280)

      HStack {
        Button("Open \(snapshot.sourceName)") {
          controller.openSource(snapshot.source)
        }
        .buttonStyle(NotchSubtleButtonStyle())
        .focusable()
        Spacer()
        if controller.isEnabled {
          Button("Disable Apple Music & Spotify") {
            controller.setEnabled(false)
          }
          .buttonStyle(NotchSubtleButtonStyle())
          .focusable()
        }
      }
    }
    .padding(14)
    .dashboardSurface(cornerRadius: 16, normalOpacity: 0.045)
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
          .focusable()
        }
        Button("Retry") {
          controller.refresh()
        }
        .buttonStyle(NotchSubtleButtonStyle())
        .focusable()
      }

      Button("Disable Music Controls") {
        controller.setEnabled(false)
      }
      .buttonStyle(NotchSubtleButtonStyle())
      .focusable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let value = Int(seconds)
    return "\(value / 60):\(String(format: "%02d", value % 60))"
  }
}
