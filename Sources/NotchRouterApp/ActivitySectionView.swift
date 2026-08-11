import AppKit
import NotchRouterCore
import SwiftUI

struct ActivitySectionView: View {
  @ObservedObject var store: ActivityStore
  @State private var searchText = ""
  @State private var selectedFilter: ActivityListFilter = .all

  var body: some View {
    VStack(spacing: 8) {
      if !store.activities.isEmpty {
        activityControls
      }

      if store.activities.isEmpty {
        emptyState
      } else if visibleGroups.isEmpty {
        noResultsState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(visibleGroups) { group in
              ActivityGroupSection(
                group: group,
                activities: store.activities(in: group, matching: searchText),
                dismiss: store.dismiss
              )
            }
          }
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
        }
      }
    }
  }

  private var activityControls: some View {
    VStack(spacing: 7) {
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .font(.caption.weight(.semibold))
          .dashboardTertiaryText()
          .accessibilityHidden(true)

        TextField("Search activities", text: $searchText)
          .font(.callout)
          .textFieldStyle(.plain)
          .accessibilityLabel("Search activities")

        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.caption)
              .dashboardTertiaryText()
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear activity search")
        }
      }
      .padding(.horizontal, 10)
      .frame(minHeight: 34)
      .dashboardSurface(cornerRadius: 10, normalOpacity: 0.065)

      HStack(spacing: 6) {
        ForEach(ActivityListFilter.allCases) { filter in
          Button {
            selectedFilter = filter
          } label: {
            HStack(spacing: 5) {
              Text(filter.title)
                .lineLimit(1)
              Text("\(count(for: filter))")
                .font(.caption2.weight(.bold).monospacedDigit())
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 17)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
          }
          .buttonStyle(
            ActivityFilterButtonStyle(isSelected: selectedFilter == filter)
          )
          .focusable()
          .accessibilityLabel("\(filter.title), \(count(for: filter)) activities")
          .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 1)
  }

  private var visibleGroups: [ActivityGroup] {
    let groups = selectedFilter.group.map { [$0] } ?? ActivityGroup.allCases
    return groups.filter {
      !store.activities(in: $0, matching: searchText).isEmpty
    }
  }

  private func count(for filter: ActivityListFilter) -> Int {
    guard let group = filter.group else { return store.activities.count }
    return store.count(in: group)
  }

  private var emptyState: some View {
    VStack(spacing: 9) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 25, weight: .light))
        .dashboardSecondaryText()
      Text("Waiting for an AI activity")
        .font(.headline)
      Text("Apps and agent hooks can publish local, authenticated updates.")
        .font(.callout)
        .dashboardSecondaryText()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var noResultsState: some View {
    VStack(spacing: 9) {
      Image(
        systemName: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass"
      )
      .font(.system(size: 25, weight: .light))
      .dashboardSecondaryText()
      Text(noResultsTitle)
        .font(.headline)
      Text(noResultsMessage)
        .font(.callout)
        .dashboardSecondaryText()
        .multilineTextAlignment(.center)
      Button(searchText.isEmpty ? "Show all" : "Clear search") {
        if searchText.isEmpty {
          selectedFilter = .all
        } else {
          searchText = ""
        }
      }
      .buttonStyle(NotchSubtleButtonStyle())
      .focusable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var noResultsTitle: String {
    searchText.isEmpty
      ? "No \(selectedFilter.title.lowercased()) activities"
      : "No matching activities"
  }

  private var noResultsMessage: String {
    searchText.isEmpty
      ? "Try another activity group."
      : "Try a different source, title, message, or activity ID."
  }
}
private enum ActivityListFilter: String, CaseIterable, Identifiable {
  case all
  case active
  case attention
  case completed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All"
    case .active: "Active"
    case .attention: "Attention"
    case .completed: "Completed"
    }
  }

  var group: ActivityGroup? {
    switch self {
    case .all: nil
    case .active: .active
    case .attention: .attentionRequired
    case .completed: .completed
    }
  }
}

private struct ActivityGroupSection: View {
  let group: ActivityGroup
  let activities: [AIActivity]
  let dismiss: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: group.symbolName)
          .font(.caption.weight(.bold))
          .dashboardTint(group.tint)
        Text(group.title.uppercased())
          .font(.caption.weight(.bold))
          .tracking(0.7)
          .dashboardSecondaryText()
        Text("\(activities.count)")
          .font(.caption2.weight(.bold).monospacedDigit())
          .dashboardTint(group.tint)
          .padding(.horizontal, 5)
          .frame(minWidth: 18, minHeight: 17)
          .background(group.tint.opacity(0.14), in: Capsule())
        Rectangle()
          .fill(.white.opacity(0.08))
          .frame(height: 0.5)
      }
      .padding(.horizontal, 2)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)

      ForEach(activities) { activity in
        ActivityCard(
          activity: activity,
          dismiss: { dismiss(activity.id) }
        )
      }
    }
  }
}

extension ActivityGroup {
  fileprivate var title: String {
    switch self {
    case .active: "Active"
    case .attentionRequired: "Needs attention"
    case .completed: "Completed"
    }
  }

  fileprivate var symbolName: String {
    switch self {
    case .active: "bolt.fill"
    case .attentionRequired: "exclamationmark.triangle.fill"
    case .completed: "checkmark.circle.fill"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .active: .cyan
    case .attentionRequired: .orange
    case .completed: .green
    }
  }
}

private struct ActivityFilterButtonStyle: ButtonStyle {
  let isSelected: Bool
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(
        isSelected || contrast == .increased
          ? Color.white
          : Color.white.opacity(0.68)
      )
      .background(
        .white.opacity(
          configuration.isPressed
            ? 0.18
            : (isSelected ? (contrast == .increased ? 0.24 : 0.14) : 0.045)
        ),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .strokeBorder(
            .white.opacity(
              contrast == .increased ? 0.82 : (isSelected ? 0.17 : 0.06)
            ),
            lineWidth: contrast == .increased ? 1.5 : 0.5
          )
      }
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

private struct ActivityCard: View {
  let activity: AIActivity
  let dismiss: () -> Void

  @State private var showsHistory = false
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top, spacing: 9) {
        ActivityStatusGlyph(state: activity.state, size: 25)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 5) {
            Text(activity.source)
              .font(.caption.weight(.semibold))
              .dashboardSecondaryText()
            Text(activity.state.shortLabel)
              .font(.caption.weight(.bold))
              .dashboardTint(activity.state.tint)
          }
          Text(activity.title)
            .font(.body.weight(.semibold))
            .lineLimit(1)
          if let message = activity.message {
            Text(message)
              .font(.callout)
              .dashboardSecondaryText()
              .lineLimit(2)
          }
        }

        Spacer(minLength: 8)

        Text(activity.updatedAt, style: .relative)
          .font(.caption)
          .dashboardTertiaryText()
      }

      if let progress = activity.progress,
        !activity.state.isTerminal
      {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .tint(activity.state.tint)
      }

      HStack(spacing: 6) {
        if activity.history.count > 1 {
          Button(showsHistory ? "Hide updates" : "\(activity.history.count) updates") {
            showsHistory.toggle()
          }
          .buttonStyle(NotchSubtleButtonStyle())
          .focusable()
        }

        Spacer()

        if let actionURL = activity.actionURL {
          Button(activity.state == .needsApproval ? "Review" : "Open") {
            NSWorkspace.shared.open(actionURL)
          }
          .buttonStyle(NotchAccentButtonStyle(tint: activity.state.tint, isCompact: true))
          .focusable()
        }

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(NotchSubtleButtonStyle())
        .focusable()
        .accessibilityLabel("Dismiss \(activity.title)")
      }

      if showsHistory {
        VStack(alignment: .leading, spacing: 7) {
          ForEach(activity.history.reversed()) { update in
            HStack(alignment: .top, spacing: 7) {
              if differentiateWithoutColor {
                Image(systemName: update.state.symbolName)
                  .font(.caption2.weight(.bold))
                  .dashboardTint(update.state.tint)
                  .frame(width: 14, height: 14)
                  .padding(.top, 1)
                  .accessibilityHidden(true)
              } else {
                Circle()
                  .fill(update.state.tint)
                  .frame(width: 7, height: 7)
                  .padding(.top, 5)
                  .accessibilityHidden(true)
              }
              VStack(alignment: .leading, spacing: 1) {
                Text(update.message ?? update.state.shortLabel)
                  .font(.callout.weight(.medium))
                  .lineLimit(2)
                Text(update.timestamp, style: .time)
                  .font(.caption)
                  .dashboardTertiaryText()
              }
            }
          }
        }
        .padding(.top, 2)
      }
    }
    .padding(12)
    .dashboardSurface(cornerRadius: 14)
  }
}
