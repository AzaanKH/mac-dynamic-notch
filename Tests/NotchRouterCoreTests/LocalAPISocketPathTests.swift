import Foundation
import Testing

@testable import NotchRouterCore

@Test
func socketStaysInApplicationSupportWhenThePathFits() {
  let support = URL(fileURLWithPath: "/Users/a/Library/Application Support/NotchRouter")
  let fallback = URL(fileURLWithPath: "/var/folders/xy/abc/C/NotchRouter")

  let url = LocalAPISocket.url(preferredDirectory: support, fallbackDirectory: fallback)
  #expect(url.path == "/Users/a/Library/Application Support/NotchRouter/api.sock")
}

@Test
func longHomeFoldersFallBackToAPathThatFitsSunPath() {
  let longHome = "/Volumes/External Users/" + String(repeating: "very-long-account-name-", count: 3)
  let support = URL(fileURLWithPath: longHome + "/Library/Application Support/NotchRouter")
  let fallback = URL(fileURLWithPath: "/var/folders/xy/abc/C/NotchRouter")

  let url = LocalAPISocket.url(preferredDirectory: support, fallbackDirectory: fallback)
  #expect(url.path == "/var/folders/xy/abc/C/NotchRouter/api.sock")
  #expect(url.path.utf8.count <= LocalAPISocket.maximumPathLength)
}

@Test
func productionSocketPathFitsSunPath() {
  #expect(LocalAPISocket.url.path.utf8.count <= LocalAPISocket.maximumPathLength)
}
