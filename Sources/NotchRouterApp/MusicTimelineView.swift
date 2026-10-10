import SwiftUI

struct MusicTimelineView: View {
  let snapshot: NowPlayingSnapshot
  let tint: Color
  let onSeek: (Double) -> Void
  @State private var scrubPosition: Double?
  @State private var isScrubbing = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let position = scrubPosition ?? snapshot.elapsed(at: context.date)
      VStack(spacing: 3) {
        if snapshot.canSeek {
          Slider(
            value: Binding(
              get: { min(snapshot.duration, max(0, position)) },
              set: { value in
                scrubPosition = value
                // Keyboard and accessibility adjustments do not begin a drag.
                if !isScrubbing { onSeek(value) }
              }
            ),
            in: 0...snapshot.duration,
            onEditingChanged: { editing in
              isScrubbing = editing
              if !editing, let target = scrubPosition { onSeek(target) }
            }
          )
          .tint(tint)
          .accessibilityLabel("Playback position")
          .accessibilityValue("\(Self.formatTime(position)) of \(Self.formatTime(snapshot.duration))")
          .help("Seek within this track")
        } else {
          ProgressView(value: position, total: snapshot.duration)
            .tint(tint)
            .help("This player does not support seeking")
        }
        HStack {
          Text(Self.formatTime(position))
          Spacer()
          Text("-\(Self.formatTime(max(0, snapshot.duration - position)))")
        }
        .font(.caption.monospacedDigit())
        .dashboardSecondaryText()
      }
    }
    .onChange(of: snapshot.sampledAt) {
      if !isScrubbing { scrubPosition = nil }
    }
  }

  static func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let value = Int(min(seconds, Double(Int.max / 2)))
    if value >= 3600 {
      return "\(value / 3600):\(String(format: "%02d:%02d", value / 60 % 60, value % 60))"
    }
    return "\(value / 60):\(String(format: "%02d", value % 60))"
  }
}
