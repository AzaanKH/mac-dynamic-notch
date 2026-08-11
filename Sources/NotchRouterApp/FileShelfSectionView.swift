import SwiftUI

struct FileShelfSectionView: View {
  @ObservedObject var store: FileShelfStore
  @ObservedObject var downloads: BrowserDownloadStore
  let isDropTargeted: Bool
  @Environment(\.colorSchemeContrast) private var contrast

  private let columns = [
    GridItem(.adaptive(minimum: 145, maximum: 160), spacing: 8)
  ]

  var body: some View {
    VStack(spacing: 8) {
      if !downloads.items.isEmpty {
        BrowserDownloadHistoryView(store: downloads)
          .padding(.horizontal, 13)
      }

      fileShelf
    }
  }

  private var fileShelf: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(
          isDropTargeted
            ? Color.orange
            : Color.white.opacity(contrast == .increased ? 0.8 : 0.14),
          style: StrokeStyle(
            lineWidth: isDropTargeted || contrast == .increased ? 2 : 1,
            dash: isDropTargeted ? [] : [5, 5]
          )
        )
        .padding(.horizontal, 13)
        .padding(.bottom, 10)

      if store.items.isEmpty {
        VStack(spacing: 9) {
          Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
            .font(.system(size: 27, weight: .light))
            .dashboardTint(isDropTargeted ? .orange : .white.opacity(0.74))
          Text(isDropTargeted ? "Release to add" : "Drop files on the notch")
            .font(.headline)
          Text("Open, reveal, AirDrop, or drag them out later.")
            .font(.callout)
            .dashboardSecondaryText()
          Button("Choose Files…") {
            store.chooseFiles()
          }
          .buttonStyle(NotchAccentButtonStyle(tint: .blue))
          .focusable()
        }
      } else {
        VStack(spacing: 4) {
          HStack(spacing: 8) {
            Button("Choose Files…") {
              store.chooseFiles()
            }
            .buttonStyle(NotchSubtleButtonStyle())
            .focusable()

            Spacer()

            Button {
              store.removeMissingItems()
            } label: {
              Label(
                store.missingItemCount == 0
                  ? "Clean Missing"
                  : (store.missingItemCount == 1
                    ? "Remove 1 Missing"
                    : "Remove \(store.missingItemCount) Missing"),
                systemImage: "trash.slash"
              )
            }
            .buttonStyle(NotchSubtleButtonStyle())
            .focusable()
            .help("Remove shelf entries whose files no longer exist")
          }
          .padding(.horizontal, 20)
          .padding(.top, 5)

          ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
              ForEach(store.items) { item in
                FileShelfCard(item: item, store: store)
              }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
          }
        }
      }

      if let error = store.lastError {
        Text(error)
          .font(.caption.weight(.medium))
          .dashboardTint(.orange)
          .padding(8)
          .background(.black.opacity(0.85), in: Capsule())
          .frame(maxHeight: .infinity, alignment: .bottom)
          .padding(.bottom, 17)
      }
    }
  }
}
private struct FileShelfCard: View {
  let item: ShelfItem
  @ObservedObject var store: FileShelfStore

  var body: some View {
    draggableCard
  }

  @ViewBuilder
  private var draggableCard: some View {
    if let url = store.resolvedURL(for: item) {
      card.draggable(url)
    } else {
      card
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Image(nsImage: store.icon(for: item))
          .resizable()
          .scaledToFit()
          .frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(itemStatus)
            .font(.caption)
            .dashboardTint(isAvailable ? .white.opacity(0.5) : .orange)
        }
      }

      HStack(spacing: 3) {
        Button {
          store.quickLook(item)
        } label: {
          Image(systemName: "eye")
        }
        .buttonStyle(NotchIconButtonStyle())
        .focusable()
        .disabled(!isAvailable)
        .accessibilityLabel("Quick Look \(item.name)")

        Button {
          store.reveal(item)
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(NotchIconButtonStyle())
        .focusable()
        .disabled(!isAvailable)
        .accessibilityLabel("Reveal \(item.name)")

        Button {
          store.airDrop(item)
        } label: {
          Image(systemName: "airplayaudio")
        }
        .buttonStyle(NotchIconButtonStyle())
        .focusable()
        .disabled(!isAvailable)
        .accessibilityLabel("AirDrop \(item.name)")

        Button {
          store.remove(item.id)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(NotchIconButtonStyle())
        .focusable()
        .accessibilityLabel("Remove \(item.name)")
      }
    }
    .padding(10)
    .dashboardSurface(cornerRadius: 13)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      store.open(item)
    }
    .help("Double-click to open")
  }

  private var isAvailable: Bool {
    store.resolvedURL(for: item) != nil
  }

  private var itemStatus: String {
    guard isAvailable else {
      return item.isDirectory ? "Missing folder" : "Missing file"
    }
    return item.isDirectory ? "Folder" : "File"
  }
}
