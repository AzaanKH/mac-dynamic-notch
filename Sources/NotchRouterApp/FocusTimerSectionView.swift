import SwiftUI

struct FocusTimerSectionView: View {
  @ObservedObject var timer: FocusTimerController
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(spacing: 14) {
      timerRing

      switch timer.phase {
      case .idle:
        setupControls
      case .running, .paused:
        activeControls
      case .completed:
        completedControls
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 18)
    .padding(.bottom, 10)
  }

  private var timerRing: some View {
    ZStack {
      Circle()
        .stroke(.white.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 8)

      Circle()
        .trim(from: 0, to: timer.progress)
        .stroke(
          timer.phase == .completed ? Color.green : Color.indigo,
          style: StrokeStyle(
            lineWidth: 8,
            lineCap: .round,
            dash: differentiateWithoutColor && timer.phase != .completed ? [7, 5] : []
          )
        )
        .rotationEffect(.degrees(-90))
        .animation(.linear(duration: 0.2), value: timer.progress)

      VStack(spacing: 4) {
        Image(systemName: timer.phase == .completed ? "checkmark" : "timer")
          .font(.system(size: 17, weight: .semibold))
          .dashboardTint(timer.phase == .completed ? .green : .indigo)
        Text(timer.formattedRemaining)
          .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
        Text(timer.stateLabel)
          .font(.caption.weight(.semibold))
          .dashboardSecondaryText()
      }
    }
    .frame(width: 154, height: 154)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(timer.stateLabel), \(timer.formattedRemaining) remaining")
  }

  private var setupControls: some View {
    VStack(spacing: 11) {
      HStack(spacing: 7) {
        ForEach(FocusTimerController.presetDurations, id: \.self) { minutes in
          Button {
            timer.selectDuration(minutes: minutes)
          } label: {
            HStack(spacing: 5) {
              Text("\(minutes) min")
              if differentiateWithoutColor, timer.selectedDurationMinutes == minutes {
                Image(systemName: "checkmark")
                  .font(.caption.weight(.bold))
              }
            }
          }
          .buttonStyle(
            FocusPresetButtonStyle(
              isSelected: timer.selectedDurationMinutes == minutes
            )
          )
          .focusable()
          .accessibilityAddTraits(
            timer.selectedDurationMinutes == minutes ? .isSelected : []
          )
        }
      }

      Button("Start Focus", action: timer.start)
        .buttonStyle(NotchAccentButtonStyle(tint: .indigo))
        .focusable()
        .keyboardShortcut(.return, modifiers: [])
    }
  }

  private var activeControls: some View {
    HStack(spacing: 8) {
      if timer.phase == .running {
        Button("Pause", action: timer.pause)
          .buttonStyle(NotchAccentButtonStyle(tint: .indigo))
          .focusable()
      } else {
        Button("Resume", action: timer.resume)
          .buttonStyle(NotchAccentButtonStyle(tint: .indigo))
          .focusable()
      }

      Button("+5 min", action: timer.addFiveMinutes)
        .buttonStyle(NotchSubtleButtonStyle())
        .focusable()
      Button("Reset", action: timer.reset)
        .buttonStyle(NotchSubtleButtonStyle())
        .focusable()
    }
  }

  private var completedControls: some View {
    HStack(spacing: 8) {
      Button("Start Again", action: timer.start)
        .buttonStyle(NotchAccentButtonStyle(tint: .green))
        .focusable()
      Button("Done", action: timer.reset)
        .buttonStyle(NotchSubtleButtonStyle())
        .focusable()
    }
  }
}


private struct FocusPresetButtonStyle: ButtonStyle {
  let isSelected: Bool
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(
        contrast == .increased
          ? Color.white
          : (isSelected ? Color.indigo : Color.white.opacity(0.74))
      )
      .frame(minWidth: 72, minHeight: 34)
      .background(
        isSelected
          ? Color.indigo.opacity(configuration.isPressed ? 0.36 : 0.24)
          : Color.white.opacity(
            configuration.isPressed ? 0.16 : (contrast == .increased ? 0.14 : 0.075)
          ),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .strokeBorder(
            .white.opacity(
              contrast == .increased ? (isSelected ? 1 : 0.65) : (isSelected ? 0.2 : 0)
            ),
            lineWidth: contrast == .increased ? 1.5 : 1
          )
      }
  }
}
