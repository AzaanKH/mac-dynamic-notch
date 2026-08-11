import AppKit
import SwiftUI

struct HoverSectionNavigation: View {
  let currentSection: NotchSection?
  let onSelect: (NotchSection) -> Void

  private var visibleSections: [NotchSection] {
    NotchSection.allCases.filter { $0 != currentSection }
  }

  var body: some View {
    HStack(spacing: 4) {
      ForEach(visibleSections) { section in
        Button {
          onSelect(section)
        } label: {
          Label(section.title, systemImage: section.symbolName)
            .labelStyle(HoverSectionLabelStyle())
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(HoverSectionButtonStyle())
        .focusable()
        .accessibilityLabel("Open \(section.title)")
      }

      Button {
        NSApp.terminate(nil)
      } label: {
        Image(systemName: "power")
          .font(.caption.weight(.bold))
          .frame(width: 32)
      }
      .buttonStyle(HoverSectionButtonStyle(tint: .red))
      .focusable()
      .accessibilityLabel("Quit NotchRouter")
      .help("Quit NotchRouter")
    }
  }
}
private struct HoverSectionLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon
        .font(.caption.weight(.semibold))
      configuration.title
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }
  }
}

private struct HoverSectionButtonStyle: ButtonStyle {
  var tint: Color = .white
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(
        tint.opacity(configuration.isPressed ? 1 : (contrast == .increased ? 1 : 0.78))
      )
      .frame(minHeight: 32)
      .background(
        tint.opacity(
          configuration.isPressed ? 0.22 : (contrast == .increased ? 0.16 : 0.08)
        ),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(
            tint.opacity(contrast == .increased ? 0.85 : 0.08),
            lineWidth: contrast == .increased ? 1.5 : 0.5
          )
      }
  }
}
