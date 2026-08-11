import Foundation
import NotchRouterCore
import Testing

@testable import NotchRouterApp

@MainActor
@Test
func fileShelfRemovesMissingItemsAndPersistsCleanup() throws {
  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("FileShelfTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: rootURL,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: rootURL) }

  let existingURL = rootURL.appendingPathComponent("existing.txt")
  let removedURL = rootURL.appendingPathComponent("removed.txt")
  try Data("existing".utf8).write(to: existingURL)
  try Data("removed".utf8).write(to: removedURL)

  let storageURL = rootURL.appendingPathComponent("shelf.json")
  let store = FileShelfStore(storageURL: storageURL)
  store.add([existingURL, removedURL])
  #expect(store.items.count == 2)
  #expect(store.missingItemCount == 0)

  try FileManager.default.removeItem(at: removedURL)

  #expect(store.missingItemCount == 1)
  #expect(store.removeMissingItems() == 1)
  #expect(store.items.map(\.path) == [existingURL.path])

  let reloadedStore = FileShelfStore(storageURL: storageURL)
  #expect(reloadedStore.items.map(\.path) == [existingURL.path])
  #expect(reloadedStore.missingItemCount == 0)
}

@MainActor
@Test
func fileShelfBookmarksRoundTripAndResolveFilesAndDirectories() throws {
  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("FileShelfBookmarkTests-\(UUID().uuidString)")
  let directoryURL = rootURL.appendingPathComponent("Reference", isDirectory: true)
  let fileURL = rootURL.appendingPathComponent("notes.txt")
  let storageURL = rootURL.appendingPathComponent("shelf.json")
  try FileManager.default.createDirectory(
    at: directoryURL,
    withIntermediateDirectories: true
  )
  try Data("notes".utf8).write(to: fileURL)
  defer { try? FileManager.default.removeItem(at: rootURL) }

  let store = FileShelfStore(storageURL: storageURL)
  store.add([fileURL, directoryURL])

  #expect(store.items.count == 2)
  #expect(store.items.allSatisfy { !$0.bookmark.isEmpty })
  #expect(store.items.first(where: { $0.path == directoryURL.path })?.isDirectory == true)

  let reloadedStore = FileShelfStore(storageURL: storageURL)
  #expect(reloadedStore.items.map(\.path) == [directoryURL.path, fileURL.path])
  for item in reloadedStore.items {
    let canonicalStoredURL = URL(fileURLWithPath: item.path)
      .resolvingSymlinksInPath()
    #expect(
      reloadedStore.resolvedURL(for: item)?.resolvingSymlinksInPath()
        == canonicalStoredURL
    )
  }
}

@MainActor
@Test
func fileShelfFallsBackToPersistedPathWhenBookmarkCannotResolve() throws {
  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("FileShelfFallbackTests-\(UUID().uuidString)")
  let fileURL = rootURL.appendingPathComponent("available.txt")
  let storageURL = rootURL.appendingPathComponent("shelf.json")
  try FileManager.default.createDirectory(
    at: rootURL,
    withIntermediateDirectories: true
  )
  try Data("available".utf8).write(to: fileURL)
  defer { try? FileManager.default.removeItem(at: rootURL) }

  var item = try ShelfItem(url: fileURL)
  item.bookmark = Data("not a bookmark".utf8)
  let data = try ActivityCoding.makeEncoder().encode([item])
  try data.write(to: storageURL)

  let store = FileShelfStore(storageURL: storageURL)
  let loadedItem = try #require(store.items.first)
  #expect(store.resolvedURL(for: loadedItem)?.path == fileURL.path)
  #expect(store.missingItemCount == 0)
}

@MainActor
@Test
func fileShelfDeduplicatesStandardizedPaths() throws {
  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("FileShelfDeduplicationTests-\(UUID().uuidString)")
  let fileURL = rootURL.appendingPathComponent("unique.txt")
  let equivalentURL = rootURL
    .appendingPathComponent("nested", isDirectory: true)
    .appendingPathComponent("..")
    .appendingPathComponent("unique.txt")
  let storageURL = rootURL.appendingPathComponent("shelf.json")
  try FileManager.default.createDirectory(
    at: rootURL,
    withIntermediateDirectories: true
  )
  try Data("unique".utf8).write(to: fileURL)
  defer { try? FileManager.default.removeItem(at: rootURL) }

  let store = FileShelfStore(storageURL: storageURL)
  store.add([fileURL, equivalentURL])

  #expect(store.items.count == 1)
  #expect(store.items.first?.path == fileURL.path)
}
