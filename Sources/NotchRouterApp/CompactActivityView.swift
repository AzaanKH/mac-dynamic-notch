import NotchRouterCore
import SwiftUI

struct CompactActivityView: View {
  let activity: AIActivity?
  let activeCount: Int
  let hardwareNotchWidth: CGFloat
  let hasPhysicalNotch: Bool
  let isPeek: Bool
  let currentSection: NotchSection?
  let onSelectSection: (NotchSection) -> Void

  var body: some View {
    VStack(spacing: 5) {
      Group {
        if let activity {
          if hasPhysicalNotch {
            physicalNotchLayout(activity)
          } else {
            softwareNotchLayout(activity)
          }
        } else {
          idleView
        }
      }

      if isPeek {
        HoverSectionNavigation(
          currentSection: currentSection,
          onSelect: onSelectSection
        )
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, isPeek ? 5 : 4)
    .padding(.bottom, isPeek ? 7 : 5)
  }

  private func physicalNotchLayout(_ activity: AIActivity) -> some View {
    HStack(spacing: 8) {
      HStack(spacing: 7) {
        ActivityStatusGlyph(state: activity.state, size: 19)
        Text(activity.source)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        ActiveCountBadge(count: activeCount)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Color.clear
        .frame(width: max(hardwareNotchWidth - 20, 120))

      VStack(alignment: .trailing, spacing: 2) {
        Text(activity.state.shortLabel)
          .font(.caption.weight(.semibold))
          .dashboardTint(activity.state.tint)
        if isPeek {
          Text(activity.title)
            .font(.caption)
            .dashboardSecondaryText()
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func softwareNotchLayout(_ activity: AIActivity) -> some View {
    HStack(spacing: 9) {
      ActivityStatusGlyph(state: activity.state, size: isPeek ? 24 : 20)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
          Text(activity.source)
            .font(.caption.weight(.semibold))
            .dashboardSecondaryText()
          Text("·")
            .dashboardTertiaryText()
          Text(activity.state.shortLabel)
            .font(.caption.weight(.semibold))
            .dashboardTint(activity.state.tint)
        }
        Text(activity.title)
          .font(
            isPeek
              ? Font.body.weight(.semibold)
              : Font.callout.weight(.semibold)
          )
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      ActiveCountBadge(count: activeCount)

      if let progress = activity.progress,
        !activity.state.isTerminal
      {
        ProgressView(value: progress)
          .progressViewStyle(.circular)
          .controlSize(.small)
          .tint(activity.state.tint)
      } else {
        Image(systemName: "chevron.down")
          .font(.caption.weight(.bold))
          .dashboardTertiaryText()
      }
    }
  }

  private var idleView: some View {
    HStack(spacing: 6) {
      Image(systemName: "sparkles")
        .font(.caption.weight(.semibold))
        .dashboardSecondaryText()
      if isPeek {
        Text("Drop files, play music, or connect an agent")
          .font(.callout.weight(.medium))
          .dashboardSecondaryText()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
private struct ActiveCountBadge: View {
  let count: Int
  @Environment(\.colorSchemeContrast) private var contrast

  @ViewBuilder
  var body: some View {
    if count > 0 {
      Text("\(count)")
        .font(.caption2.weight(.bold).monospacedDigit())
        .foregroundStyle(contrast == .increased ? Color.black : Color.cyan)
        .padding(.horizontal, 6)
        .frame(minWidth: 20, minHeight: 18)
        .background(
          contrast == .increased
            ? Color.white
            : Color.cyan.opacity(0.17),
          in: Capsule()
        )
        .overlay {
          Capsule()
            .strokeBorder(
              contrast == .increased ? Color.white : Color.cyan.opacity(0.3),
              lineWidth: contrast == .increased ? 1.5 : 0.5
            )
        }
        .fixedSize()
        .layoutPriority(1)
        .accessibilityLabel(
          count == 1 ? "1 active activity" : "\(count) active activities"
        )
    }
  }
}
