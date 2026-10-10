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

enum NotchMotion {
  // The window, outline, and content all move on this spring so they stay in
  // step. Keep the bounce low: the transition canvas only reserves a small
  // margin for overshoot.
  static let surface = Animation.spring(duration: 0.42, bounce: 0.16)
  static let reduced = Animation.linear(duration: 0.12)
  static let section = Animation.spring(duration: 0.34, bounce: 0.12)
}

/// Content entering or leaving the surface blurs and settles toward the top
/// edge, which hides layout differences while the outline changes size.
struct NotchMorphTransition: Transition {
  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .blur(radius: phase.isIdentity ? 0 : 8)
      .opacity(phase.isIdentity ? 1 : 0)
      .scaleEffect(phase.isIdentity ? 1 : 0.96, anchor: .top)
  }
}

/// The incoming section slides in from the side of its tab. Outgoing content
/// fades in place: a removed view keeps the transition from its last render,
/// so a direction-dependent exit could move the wrong way.
struct SectionEntranceTransition: Transition {
  /// 1 when the new section is to the right of the previous one, -1 otherwise.
  let direction: CGFloat

  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .offset(x: phase == .willAppear ? 28 * direction : 0)
      .blur(radius: phase.isIdentity ? 0 : 4)
      .opacity(phase.isIdentity ? 1 : 0)
  }
}

struct NotchSurfaceMetrics: Equatable {
  /// Width of each concave top corner that flares into the menu bar.
  let earRadius: CGFloat
  let bottomRadius: CGFloat

  init(mode: SurfaceMode) {
    switch mode {
    case .compact:
      earRadius = 6
      bottomRadius = 10
    case .peek:
      earRadius = 10
      bottomRadius = 18
    case .expanded:
      earRadius = 14
      bottomRadius = 24
    }
  }
}

/// The notch outline. The body is inset by `earRadius` on both sides and the
/// top corners curve outward, so the surface reads as part of the cutout.
struct NotchSurfaceShape: Shape {
  var earRadius: CGFloat
  var bottomRadius: CGFloat

  init(_ metrics: NotchSurfaceMetrics) {
    earRadius = metrics.earRadius
    bottomRadius = metrics.bottomRadius
  }

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(earRadius, bottomRadius) }
    set {
      earRadius = newValue.first
      bottomRadius = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let ear = max(0, min(earRadius, rect.width / 4, rect.height / 2))
    let bodyMinX = rect.minX + ear
    let bodyMaxX = rect.maxX - ear
    let bottom = max(0, min(bottomRadius, (bodyMaxX - bodyMinX) / 2, rect.height - ear))

    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: bodyMinX, y: rect.minY + ear),
      control: CGPoint(x: bodyMinX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - bottom))
    path.addQuadCurve(
      to: CGPoint(x: bodyMinX + bottom, y: rect.maxY),
      control: CGPoint(x: bodyMinX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: bodyMaxX - bottom, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: bodyMaxX, y: rect.maxY - bottom),
      control: CGPoint(x: bodyMaxX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + ear))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY),
      control: CGPoint(x: bodyMaxX, y: rect.minY)
    )
    path.closeSubpath()
    return path
  }
}

struct MusicAmbientGlow: View {
  let palette: MusicArtworkPalette
  let metrics: NotchSurfaceMetrics
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    NotchSurfaceShape(metrics)
      .fill(
        .linearGradient(
          Gradient(colors: [
            palette.accent.opacity(0.30),
            palette.ambient.opacity(0.20),
            .black.opacity(0),
          ]),
          startPoint: .top,
          endPoint: UnitPoint(x: 0.5, y: 0.9)
        )
      )
      .overlay {
        NotchSurfaceShape(metrics)
          .fill(
            .radialGradient(
              Gradient(colors: [palette.accent.opacity(0.26), .clear]),
              center: UnitPoint(x: 0.5, y: 0.06),
              startRadius: 6,
              endRadius: 170
            )
          )
      }
      .opacity(contrast == .increased ? 0 : 1)
  }
}

struct ActivityStatusGlyph: View {
  let state: ActivityState
  let size: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var approvalBounces = 0

  var body: some View {
    Image(systemName: state.symbolName)
      .font(.system(size: size * 0.43, weight: .semibold))
      .dashboardTint(state.tint)
      .symbolEffect(.pulse, isActive: state == .running && !reduceMotion)
      .symbolEffect(.bounce, options: .repeat(2), value: approvalBounces)
      .symbolSwap(on: state)
      // Bounce only on the change into approval, not when a view is created
      // already in that state or when the request is resolved.
      .onChange(of: state) { _, newState in
        if newState == .needsApproval, !reduceMotion { approvalBounces += 1 }
      }
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

/// Draws the resting and pressed tab. The selected fill is a separate
/// `NotchSectionSelectionIndicator`, so it can slide between tabs.
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
        Color.white.opacity(
          configuration.isPressed ? 0.14 : (contrast == .increased ? 0.08 : 0.035)
        ),
        in: RoundedRectangle(cornerRadius: 9)
      )
      .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 9))
  }
}

struct NotchSectionSelectionIndicator: View {
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    RoundedRectangle(cornerRadius: 9)
      .fill(.white.opacity(contrast == .increased ? 0.15 : 0.09))
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(
            .white.opacity(contrast == .increased ? 0.95 : 0.22),
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
      .contentShape(.focusEffect, Capsule())
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
      .contentShape(.focusEffect, Circle())
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
      .contentShape(.focusEffect, Capsule())
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
      .contentShape(.focusEffect, Circle())
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

// MARK: - Live values

/// Animated waveform while playing; swaps to a pause glyph when paused.
struct PlaybackIndicator: View {
  let isPlaying: Bool
  let tint: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Image(systemName: isPlaying ? "waveform" : "pause.fill")
      .symbolEffect(.variableColor.iterative, isActive: isPlaying && !reduceMotion)
      .symbolSwap(on: isPlaying)
      .dashboardTint(tint)
      .accessibilityLabel(isPlaying ? "Playing" : "Paused")
  }
}

struct PlayPauseSymbol: View {
  let isPlaying: Bool

  var body: some View {
    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
      .symbolSwap(on: isPlaying)
  }
}

private struct SymbolSwapModifier<Value: Equatable>: ViewModifier {
  let value: Value
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
      .animation(reduceMotion ? NotchMotion.reduced : .snappy(duration: 0.25), value: value)
  }
}

private struct RollingNumberModifier<Value: Equatable>: ViewModifier {
  let value: Value
  let countsDown: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: countsDown))
      .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: value)
  }
}

extension View {
  /// Animates a change of SF Symbol when `value` changes; fades instead under
  /// Reduce Motion.
  func symbolSwap<Value: Equatable>(on value: Value) -> some View {
    modifier(SymbolSwapModifier(value: value))
  }

  /// Rolls changed digits into place instead of replacing the whole label.
  func rollingNumber<Value: Equatable>(_ value: Value, countsDown: Bool = false) -> some View {
    modifier(RollingNumberModifier(value: value, countsDown: countsDown))
  }
}

// MARK: - Lists

private struct ListChangeAnimationModifier<Value: Equatable>: ViewModifier {
  let value: Value
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.animation(reduceMotion ? NotchMotion.reduced : NotchMotion.section, value: value)
  }
}

private struct ListRowTransitionModifier: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.transition(
      reduceMotion
        ? AnyTransition.opacity
        : AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    )
  }
}

extension View {
  /// Animates rows in and out when `value` changes. Pass row identities (and
  /// anything that regroups rows), not values that change on every update.
  func animatesListChanges<Value: Equatable>(_ value: Value) -> some View {
    modifier(ListChangeAnimationModifier(value: value))
  }

  func notchListRowTransition() -> some View {
    modifier(ListRowTransitionModifier())
  }
}
