import AppKit
import SwiftUI

struct FileShelfSectionView: View {
  let store: FileShelfStore
  let downloads: BrowserDownloadStore
  let isDropTargeted: Bool
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let workspace = NSWorkspace.shared.notificationCenter

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
    .task(id: store.items) { await store.refreshPresentation() }
    // A reconnected volume can make missing items available again without
    // changing the shelf itself.
    .onReceive(workspace.publisher(for: NSWorkspace.didMountNotification)) { _ in
      Task { await store.refreshPresentation() }
    }
    .onReceive(workspace.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
      Task { await store.refreshPresentation() }
    }
  }

  private var fileShelf: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(.orange.opacity(isDropTargeted ? 0.08 : 0))
        .overlay {
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
        }
        .shadow(color: .orange.opacity(isDropTargeted ? 0.45 : 0), radius: 12)
        .scaleEffect(isDropTargeted && !reduceMotion ? 1.015 : 1)
        .padding(.horizontal, 13)
        .padding(.bottom, 10)

      if store.items.isEmpty {
        VStack(spacing: 9) {
          Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
            .font(.system(size: 27, weight: .light))
            .dashboardTint(isDropTargeted ? .orange : .white.opacity(0.74))
            .symbolSwap(on: isDropTargeted)
          Text(isDropTargeted ? "Release to add" : "Drop files on the notch")
            .font(.headline)
          Text("Open, reveal, AirDrop, or drag them out later.")
            .font(.callout)
            .dashboardSecondaryText()
          Button("Choose Files…") {
            store.chooseFiles()
          }
          .buttonStyle(NotchAccentButtonStyle(tint: .blue))
        }
      } else {
        VStack(spacing: 4) {
          HStack(spacing: 8) {
            Button("Choose Files…") {
              store.chooseFiles()
            }
            .buttonStyle(NotchSubtleButtonStyle())

            Spacer()

            Button {
              Task { await store.removeMissingItems() }
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
            .help("Remove shelf entries whose files no longer exist")
          }
          .padding(.horizontal, 20)
          .padding(.top, 5)

          ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
              ForEach(store.items) { item in
                FileShelfCard(item: item, store: store)
                  .notchListRowTransition()
              }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .animatesListChanges(store.items.map(\.id))
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
    .animation(
      reduceMotion ? NotchMotion.reduced : .spring(duration: 0.3, bounce: 0.3),
      value: isDropTargeted
    )
  }
}
private struct FileShelfCard: View {
  let item: ShelfItem
  let store: FileShelfStore

  var body: some View {
    draggableCard
  }

  @ViewBuilder
  private var draggableCard: some View {
    if let url = store.presentations[item.id]?.url {
      card.draggable(url)
    } else {
      card
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Image(nsImage: store.presentations[item.id]?.icon
          ?? NSImage(systemSymbolName: item.isDirectory ? "folder" : "doc", accessibilityDescription: nil)!)
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
          Task { await store.quickLook(item) }
        } label: {
          Image(systemName: "eye")
        }
        .buttonStyle(NotchIconButtonStyle())
        .accessibilityLabel("Quick Look \(item.name)")

        Button {
          Task { await store.reveal(item) }
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(NotchIconButtonStyle())
        .accessibilityLabel("Reveal \(item.name)")

        Button {
          Task { await store.airDrop(item) }
        } label: {
          Image(systemName: "airplayaudio")
        }
        .buttonStyle(NotchIconButtonStyle())
        .accessibilityLabel("AirDrop \(item.name)")

        Button {
          store.remove(item.id)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(NotchIconButtonStyle())
        .accessibilityLabel("Remove \(item.name)")
      }
    }
    .padding(10)
    .dashboardSurface(cornerRadius: 13)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      Task { await store.open(item) }
    }
    .help("Double-click to open")
  }

  private var isAvailable: Bool {
    store.presentations[item.id]?.url != nil
  }

  private var itemStatus: String {
    guard store.presentations[item.id] != nil else { return "Checking…" }
    guard isAvailable else {
      return item.isDirectory ? "Missing folder" : "Missing file"
    }
    return item.isDirectory ? "Folder" : "File"
  }
}
