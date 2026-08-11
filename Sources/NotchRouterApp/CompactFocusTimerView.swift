import SwiftUI

struct CompactFocusTimerView: View {
  @ObservedObject var timer: FocusTimerController
  let hardwareNotchWidth: CGFloat
  let hasPhysicalNotch: Bool
  let isPeek: Bool
  let onSelectSection: (NotchSection) -> Void
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(spacing: 5) {
      if hasPhysicalNotch {
        physicalNotchLayout
      } else {
        softwareNotchLayout
      }

      if isPeek {
        HoverSectionNavigation(
          currentSection: .focus,
          onSelect: onSelectSection
        )
      }
    }
    .padding(.horizontal, 11)
    .padding(.top, isPeek ? 5 : 4)
    .padding(.bottom, isPeek ? 7 : 5)
  }

  private var physicalNotchLayout: some View {
    HStack(spacing: 8) {
      HStack(spacing: 7) {
        timerGlyph(size: 19)
        Text("Focus")
          .font(.callout.weight(.semibold))
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Color.clear
        .frame(width: max(hardwareNotchWidth - 20, 120))

      HStack(spacing: 7) {
        VStack(alignment: .trailing, spacing: 1) {
          Text(timer.formattedRemaining)
            .font(.callout.weight(.bold).monospacedDigit())
            .dashboardTint(.indigo)
          if isPeek {
            Text(timer.stateLabel)
              .font(.caption)
              .dashboardSecondaryText()
          }
        }
        if isPeek {
          quickControl
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private var softwareNotchLayout: some View {
    HStack(spacing: 9) {
      timerGlyph(size: isPeek ? 26 : 21)

      VStack(alignment: .leading, spacing: 2) {
        Text(timer.stateLabel)
          .font(.caption.weight(.semibold))
          .dashboardSecondaryText()
        Text(timer.formattedRemaining)
          .font(
            (isPeek ? Font.title3 : Font.callout)
              .weight(.bold)
              .monospacedDigit()
          )
      }

      Spacer(minLength: 8)

      if isPeek {
        quickControl
      } else {
        Image(systemName: timer.phase == .completed ? "checkmark" : "chevron.down")
          .font(.caption.weight(.bold))
          .dashboardTint(timer.phase == .completed ? .green : .white.opacity(0.6))
      }
    }
  }

  private func timerGlyph(size: CGFloat) -> some View {
    ZStack {
      Circle()
        .stroke(
          .white.opacity(contrast == .increased ? 0.5 : 0.2),
          lineWidth: 2
        )
      Circle()
        .trim(from: 0, to: timer.progress)
        .stroke(
          timer.phase == .completed ? Color.green : Color.indigo,
          style: StrokeStyle(
            lineWidth: 2,
            lineCap: .round,
            dash: differentiateWithoutColor && timer.phase != .completed ? [3, 2] : []
          )
        )
        .rotationEffect(.degrees(-90))
      Image(systemName: timer.phase == .completed ? "checkmark" : "timer")
        .font(.system(size: size * 0.38, weight: .bold))
        .dashboardTint(timer.phase == .completed ? .green : .indigo)
    }
    .frame(width: size, height: size)
  }

  @ViewBuilder
  private var quickControl: some View {
    switch timer.phase {
    case .running:
      Button(action: timer.pause) {
        Image(systemName: "pause.fill")
      }
      .buttonStyle(NotchCircularButtonStyle(size: 36, isPrimary: true, typography: .compact))
      .focusable()
      .accessibilityLabel("Pause focus timer")
    case .paused:
      Button(action: timer.resume) {
        Image(systemName: "play.fill")
      }
      .buttonStyle(NotchCircularButtonStyle(size: 36, isPrimary: true, typography: .compact))
      .focusable()
      .accessibilityLabel("Resume focus timer")
    case .completed:
      Button(action: timer.start) {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(NotchCircularButtonStyle(size: 36, isPrimary: true, typography: .compact))
      .focusable()
      .accessibilityLabel("Restart focus timer")
    case .idle:
      EmptyView()
    }
  }
}
