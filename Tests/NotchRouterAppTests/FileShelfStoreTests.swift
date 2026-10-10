import Foundation
import NotchRouterCore
import Testing

@testable import NotchRouterApp

@MainActor
@Test
func fileShelfCreatesItsStorageDirectoryWithPrivatePermissions() async throws {
  let rootURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("FileShelfDirectoryPermissionsTests-\(UUID().uuidString)")
  let storageDirectoryURL = rootURL.appendingPathComponent("shelf-data")
  let storageURL = storageDirectoryURL.appendingPathComponent("shelf.json")
  let fileURL = rootURL.appendingPathComponent("document.txt")
  try FileManager.default.createDirectory(
    at: rootURL,
    withIntermediateDirectories: true
  )
  try FileManager.default.createDirectory(
    at: storageDirectoryURL,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o755]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: storageDirectoryURL.path
  )
  try Data("document".utf8).write(to: fileURL)
  defer { try? FileManager.default.removeItem(at: rootURL) }

  let store = FileShelfStore(storageURL: storageURL)
  await store.add([fileURL])

  await store.flushPersistence()
  let attributes = try FileManager.default.attributesOfItem(
    atPath: storageDirectoryURL.path
  )
  let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
  #expect(permissions.intValue & 0o777 == 0o700)
  await store.flushPersistence()
}

@MainActor
@Test
func fileShelfRemovesMissingItemsAndPersistsCleanup() async throws {
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
  await store.add([existingURL, removedURL])
  #expect(store.items.count == 2)
  await store.refreshPresentation()
  #expect(store.missingItemCount == 0)

  try FileManager.default.removeItem(at: removedURL)

  await store.refreshPresentation()
  #expect(store.missingItemCount == 1)
  #expect(await store.removeMissingItems() == 1)
  #expect(store.items.map(\.path) == [existingURL.path])

  await store.flushPersistence()
  let reloadedStore = FileShelfStore(storageURL: storageURL)
  #expect(reloadedStore.items.map(\.path) == [existingURL.path])
  #expect(reloadedStore.missingItemCount == 0)
  await store.flushPersistence()
  await reloadedStore.flushPersistence()
}

@MainActor
@Test
func fileShelfBookmarksRoundTripAndResolveFilesAndDirectories() async throws {
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
  await store.add([fileURL, directoryURL])

  #expect(store.items.count == 2)
  #expect(store.items.allSatisfy { !$0.bookmark.isEmpty })
  #expect(store.items.first(where: { $0.path == directoryURL.path })?.isDirectory == true)

  await store.flushPersistence()
  let reloadedStore = FileShelfStore(storageURL: storageURL)
  #expect(reloadedStore.items.map(\.path) == [directoryURL.path, fileURL.path])
  for item in reloadedStore.items {
    let canonicalStoredURL = URL(fileURLWithPath: item.path)
      .resolvingSymlinksInPath()
    #expect(
      await reloadedStore.resolvedURL(for: item)?.resolvingSymlinksInPath()
        == canonicalStoredURL
    )
  }
  await store.flushPersistence()
  await reloadedStore.flushPersistence()
}

@MainActor
@Test
func fileShelfFallsBackToPersistedPathWhenBookmarkCannotResolve() async throws {
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
  #expect(await store.resolvedURL(for: loadedItem)?.path == fileURL.path)
  await store.refreshPresentation()
  #expect(store.missingItemCount == 0)
  await store.flushPersistence()
}

@MainActor
@Test
func fileShelfDeduplicatesStandardizedPaths() async throws {
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
  await store.add([fileURL, equivalentURL])

  #expect(store.items.count == 1)
  #expect(store.items.first?.path == fileURL.path)
  await store.flushPersistence()
}

@MainActor
@Test
func shelfPresentationIsCachedUntilExplicitRefreshAndActionsRevalidate() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("sample.txt")
  try Data("test".utf8).write(to: file)
  let store = FileShelfStore(storageURL: directory.appendingPathComponent("shelf.json"))
  await store.add([file])
  await store.refreshPresentation()
  let item = try #require(store.items.first)
  #expect(store.presentations[item.id]?.url != nil)
  try FileManager.default.removeItem(at: file)
  #expect(store.missingItemCount == 0, "Rendering reads the cached snapshot without disk access")
  #expect(await store.resolvedURL(for: item) == nil, "Actions still check whether the file exists")
  await store.refreshPresentation()
  #expect(store.missingItemCount == 1)
  try Data("restored".utf8).write(to: file)
  await store.refreshPresentation()
  #expect(store.missingItemCount == 0)
  await store.flushPersistence()
}
