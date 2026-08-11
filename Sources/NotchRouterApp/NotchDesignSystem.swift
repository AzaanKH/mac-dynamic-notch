import NotchRouterCore
import SwiftUI

// MARK: - Text and surface modifiers

private enum DashboardTextProminence {
  case secondary
  case tertiary
}

private struct DashboardTextContrastModifier: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  let prominence: DashboardTextProminence

  private var color: Color {
    if contrast == .increased {
      return .white
    }

    switch prominence {
    case .secondary:
      return .white.opacity(0.74)
    case .tertiary:
      return .white.opacity(0.6)
    }
  }

  func body(content: Content) -> some View {
    content.foregroundStyle(color)
  }
}

private struct DashboardTintContrastModifier: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  let tint: Color

  func body(content: Content) -> some View {
    content.foregroundStyle(contrast == .increased ? Color.white : tint)
  }
}

private struct DashboardSurfaceModifier: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  let cornerRadius: CGFloat
  let normalOpacity: Double

  func body(content: Content) -> some View {
    content
      .background(
        .white.opacity(contrast == .increased ? 0.15 : normalOpacity),
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            .white.opacity(contrast == .increased ? 0.82 : 0.08),
            lineWidth: contrast == .increased ? 1.5 : 0.5
          )
      }
  }
}

extension View {
  func dashboardSecondaryText() -> some View {
    modifier(DashboardTextContrastModifier(prominence: .secondary))
  }

  func dashboardTertiaryText() -> some View {
    modifier(DashboardTextContrastModifier(prominence: .tertiary))
  }

  func dashboardTint(_ tint: Color) -> some View {
    modifier(DashboardTintContrastModifier(tint: tint))
  }

  func dashboardSurface(cornerRadius: CGFloat, normalOpacity: Double = 0.055) -> some View {
    modifier(
      DashboardSurfaceModifier(
        cornerRadius: cornerRadius,
        normalOpacity: normalOpacity
      )
    )
  }
}

// MARK: - Shape and status

struct NotchSurfaceShape: Shape {
  func path(in rect: CGRect) -> Path {
    UnevenRoundedRectangle(
      topLeadingRadius: 4,
      bottomLeadingRadius: 22,
      bottomTrailingRadius: 22,
      topTrailingRadius: 4,
      style: .continuous
    ).path(in: rect)
  }
}

struct ActivityStatusGlyph: View {
  let state: ActivityState
  let size: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Image(systemName: state.symbolName)
      .font(.system(size: size * 0.43, weight: .semibold))
      .dashboardTint(state.tint)
      .frame(width: size, height: size)
      .background(
        state.tint.opacity(contrast == .increased ? 0.34 : 0.18),
        in: Circle()
      )
      .overlay {
        Circle()
          .strokeBorder(
            (contrast == .increased ? Color.white : state.tint)
              .opacity(contrast == .increased ? 0.9 : 0.22),
            lineWidth: contrast == .increased ? 1.5 : 0.5
          )
      }
  }
}

// MARK: - Button styles

struct NotchSectionButtonStyle: ButtonStyle {
  let isSelected: Bool
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(
        isSelected || contrast == .increased
          ? Color.white
          : Color.white.opacity(0.74)
      )
      .background(
        isSelected
          ? Color.white.opacity(
            configuration.isPressed ? 0.28 : (contrast == .increased ? 0.22 : 0.12)
          )
          : Color.white.opacity(
            configuration.isPressed ? 0.14 : (contrast == .increased ? 0.08 : 0.035)
          ),
        in: RoundedRectangle(cornerRadius: 9)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(
            .white.opacity(
              isSelected ? (contrast == .increased ? 0.95 : 0.22) : 0
            ),
            lineWidth: contrast == .increased ? 1.5 : 1
          )
      }
  }
}

struct NotchSubtleButtonStyle: ButtonStyle {
  var isProminent = false
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(
        contrast == .increased || isProminent
          ? Color.white
          : Color.white.opacity(0.78)
      )
      .padding(.horizontal, 10)
      .frame(minHeight: 32)
      .background(
        .white.opacity(
          configuration.isPressed
            ? 0.18
            : (contrast == .increased ? 0.14 : (isProminent ? 0.11 : 0.075))
        ),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .strokeBorder(
            .white.opacity(contrast == .increased ? 0.75 : (isProminent ? 0.18 : 0.08)),
            lineWidth: contrast == .increased ? 1.5 : 0.5
          )
      }
  }
}

struct NotchIconButtonStyle: ButtonStyle {
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(contrast == .increased ? Color.white : Color.white.opacity(0.78))
      .frame(width: 32, height: 32)
      .background(
        .white.opacity(
          configuration.isPressed ? 0.18 : (contrast == .increased ? 0.14 : 0.075)
        ),
        in: Circle()
      )
      .overlay {
        Circle()
          .strokeBorder(
            .white.opacity(contrast == .increased ? 0.75 : 0.08),
            lineWidth: contrast == .increased ? 1.5 : 0.5
          )
      }
  }
}

struct NotchAccentButtonStyle: ButtonStyle {
  let tint: Color
  var isCompact = false
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.bold))
      .foregroundStyle(contrast == .increased ? Color.white : tint)
      .padding(.horizontal, isCompact ? 12 : 14)
      .frame(minHeight: isCompact ? 32 : 34)
      .background(
        tint.opacity(configuration.isPressed ? 0.36 : (contrast == .increased ? 0.32 : 0.2)),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .strokeBorder(
            (contrast == .increased ? Color.white : tint)
              .opacity(contrast == .increased ? 0.95 : 0.28),
            lineWidth: contrast == .increased ? 1.5 : 1
          )
      }
  }
}

enum NotchCircularControlTypography {
  case compact
  case dashboard
}

struct NotchCircularButtonStyle: ButtonStyle {
  let size: CGFloat
  var isPrimary = false
  var typography: NotchCircularControlTypography = .dashboard
  @Environment(\.colorSchemeContrast) private var contrast

  private var labelFont: Font {
    switch typography {
    case .compact:
      .caption.weight(.bold)
    case .dashboard:
      .system(size: isPrimary ? 15 : 11, weight: .semibold)
    }
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(labelFont)
      .foregroundStyle(isPrimary ? Color.black : Color.white)
      .frame(width: size, height: size)
      .background(
        isPrimary
          ? Color.white.opacity(configuration.isPressed ? 0.76 : 1)
          : Color.white.opacity(
            configuration.isPressed ? 0.2 : (contrast == .increased ? 0.18 : 0.1)
          ),
        in: Circle()
      )
      .overlay {
        Circle()
          .strokeBorder(
            .white.opacity(contrast == .increased ? 0.9 : 0.12),
            lineWidth: contrast == .increased ? 1.5 : 0.5
          )
      }
  }
}

// MARK: - Activity presentation

extension ActivityState {
  var shortLabel: String {
    switch self {
    case .queued: "Queued"
    case .running: "Working"
    case .needsApproval: "Needs review"
    case .stale: "Disconnected"
    case .succeeded: "Completed"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }

  var symbolName: String {
    switch self {
    case .queued: "clock"
    case .running: "sparkles"
    case .needsApproval: "hand.raised.fill"
    case .stale: "wifi.slash"
    case .succeeded: "checkmark"
    case .failed: "exclamationmark"
    case .cancelled: "xmark"
    }
  }

  var tint: Color {
    switch self {
    case .queued: .gray
    case .running: .cyan
    case .needsApproval: .orange
    case .stale: .gray
    case .succeeded: .green
    case .failed: .red
    case .cancelled: .secondary
    }
  }

  var notificationLabel: String {
    switch self {
    case .queued: "Queued"
    case .running: "Work is in progress"
    case .needsApproval: "Your review is required"
    case .stale: "No recent heartbeat"
    case .succeeded: "Completed successfully"
    case .failed: "The activity failed"
    case .cancelled: "The activity was cancelled"
    }
  }
}
