import SwiftUI

struct ClipboardSectionView: View {
  @ObservedObject var store: ClipboardStore
  @State private var searchText = ""

  var body: some View {
    Group {
      if !store.isEnabled {
        onboarding
      } else if store.entries.isEmpty {
        emptyState
      } else {
        VStack(spacing: 8) {
          searchField

          if filteredEntries.isEmpty {
            VStack(spacing: 7) {
              Image(systemName: "magnifyingglass")
                .font(.title2)
                .dashboardSecondaryText()
              Text("No matching clips")
                .font(.headline)
              Text("Try a different phrase or app name.")
                .font(.callout)
                .dashboardSecondaryText()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              LazyVStack(spacing: 7) {
                ForEach(filteredEntries) { entry in
                  ClipboardRow(entry: entry, store: store)
                }
              }
              .padding(.horizontal, 14)
              .padding(.bottom, 10)
            }
          }
        }
      }
    }
  }

  private var filteredEntries: [ClipboardEntry] {
    store.entries.filter { $0.matchesSearch(searchText) }
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.caption.weight(.semibold))
        .dashboardTertiaryText()
      TextField("Search clips or source apps", text: $searchText)
        .textFieldStyle(.plain)
        .font(.callout)
        .accessibilityLabel("Search clipboard history")
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .dashboardTertiaryText()
        .accessibilityLabel("Clear clipboard search")
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .dashboardSurface(cornerRadius: 10, normalOpacity: 0.07)
    .padding(.horizontal, 14)
  }

  private var onboarding: some View {
    VStack(spacing: 10) {
      Image(systemName: "list.clipboard")
        .font(.system(size: 28, weight: .light))
        .dashboardTint(.purple)
      Text("Keep a local clipboard history")
        .font(.headline)
      Text(
        "Text and images copied after you enable this are stored only on this Mac. Concealed, transient, and password-manager pasteboards are excluded."
      )
      .font(.callout)
      .dashboardSecondaryText()
      .multilineTextAlignment(.center)
      .frame(maxWidth: 350)
      Button("Enable Clipboard History") {
        store.setEnabled(true)
      }
      .buttonStyle(NotchAccentButtonStyle(tint: .purple))
      .focusable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack(spacing: 9) {
      Image(systemName: "doc.on.clipboard")
        .font(.system(size: 26, weight: .light))
        .dashboardSecondaryText()
      Text("Copy text or an image")
        .font(.headline)
      Text("New copies will appear here.")
        .font(.callout)
        .dashboardSecondaryText()
      Button("Turn Off History") {
        store.setEnabled(false)
      }
      .buttonStyle(NotchSubtleButtonStyle())
      .focusable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
private struct ClipboardRow: View {
  let entry: ClipboardEntry
  @ObservedObject var store: ClipboardStore

  var body: some View {
    HStack(alignment: entry.isImage ? .center : .top, spacing: 10) {
      preview

      VStack(alignment: .leading, spacing: 4) {
        if let text = entry.text {
          Text(text)
            .font(.callout.weight(.medium))
            .lineLimit(3)
            .textSelection(.enabled)
        } else {
          Text(imageDescription)
            .font(.callout.weight(.semibold))
        }
        HStack(spacing: 5) {
          if let source = entry.sourceApplication {
            Text(source)
          }
          Text(entry.createdAt, style: .relative)
          if entry.isTextTruncated {
            Text("Truncated at 10,000 characters")
              .dashboardTint(.orange)
          }
        }
        .font(.caption)
        .dashboardTertiaryText()
      }

      Spacer(minLength: 8)

      Button {
        store.togglePinned(entry.id)
      } label: {
        Image(systemName: entry.isPinned ? "pin.fill" : "pin")
          .dashboardTint(entry.isPinned ? .orange : .white)
      }
      .buttonStyle(NotchIconButtonStyle())
      .focusable()
      .accessibilityLabel(entry.isPinned ? "Unpin clipboard item" : "Pin clipboard item")

      Button {
        store.copy(entry)
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .buttonStyle(NotchIconButtonStyle())
      .focusable()
      .accessibilityLabel("Copy clipboard item")

      Button {
        store.remove(entry.id)
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(NotchIconButtonStyle())
      .focusable()
      .accessibilityLabel("Remove clipboard item")
    }
    .padding(10)
    .dashboardSurface(cornerRadius: 13, normalOpacity: 0.05)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      store.copy(entry)
    }
    .contextMenu {
      Button(entry.isPinned ? "Unpin" : "Pin") {
        store.togglePinned(entry.id)
      }
      if let source = entry.sourceApplication,
        entry.sourceApplicationBundleIdentifier != nil
      {
        Button("Exclude \(source) from Capture") {
          store.excludeSourceApplication(for: entry)
        }
      }
    }
    .help("Double-click to copy")
  }

  @ViewBuilder
  private var preview: some View {
    if let image = store.image(for: entry) {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: 62, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(.white.opacity(0.1))
        }
        .accessibilityLabel(imageDescription)
    } else {
      Image(systemName: entry.isImage ? "photo" : "text.alignleft")
        .font(.callout.weight(.semibold))
        .dashboardTint(.purple)
        .frame(width: 32, height: 32)
        .background(.purple.opacity(0.14), in: Circle())
    }
  }

  private var imageDescription: String {
    guard let width = entry.imagePixelWidth,
      let height = entry.imagePixelHeight
    else { return "Image" }
    return "Image · \(width) × \(height)"
  }
}
