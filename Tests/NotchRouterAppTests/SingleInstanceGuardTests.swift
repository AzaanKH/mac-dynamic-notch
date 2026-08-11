import Foundation
@testable import NotchRouterApp
import Testing

@Test
func singleInstanceGuardRejectsASecondOwnerAndReleasesItsLock() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let lockURL = directory.appendingPathComponent("instance.lock")
  defer { try? FileManager.default.removeItem(at: directory) }

  var firstGuard: SingleInstanceGuard? = try SingleInstanceGuard.acquire(
    at: lockURL
  )
  #expect(firstGuard != nil)
  #expect(try SingleInstanceGuard.acquire(at: lockURL) == nil)

  firstGuard = nil
  let nextGuard = try SingleInstanceGuard.acquire(at: lockURL)
  #expect(nextGuard != nil)
}
