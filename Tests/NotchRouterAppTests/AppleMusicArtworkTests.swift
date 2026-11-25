import Foundation
import Testing

@testable import NotchRouterApp

private let separator = String(UnicodeScalar(31))

private func appleMusicOutput(trackID: String?) -> String {
  var values = ["playing", "Song", "Artist", "Album", "200", "10", ""]
  if let trackID { values.append(trackID) }
  return values.joined(separator: separator) + "\n"
}

@Test
func appleMusicQueryReadsOnlyHexadecimalTrackIDs() throws {
  let valid = try #require(
    MusicScriptRunner.parse(appleMusicOutput(trackID: "0A1B2C3D4E5F6789"), source: .appleMusic)
  )
  #expect(valid.trackID == "0A1B2C3D4E5F6789")

  // IDs are placed in a later script, so anything but hex digits is dropped.
  for unsafe in ["\" & (do shell script \"id\") & \"", "12 34", "ＡＢ", String(repeating: "A", count: 33), ""] {
    let snapshot = try #require(
      MusicScriptRunner.parse(appleMusicOutput(trackID: unsafe), source: .appleMusic)
    )
    #expect(snapshot.trackID == nil)
    #expect(snapshot.title == "Song")
  }

  // Seven-field replies from an older script shape still parse.
  let legacy = try #require(MusicScriptRunner.parse(appleMusicOutput(trackID: nil), source: .appleMusic))
  #expect(legacy.trackID == nil)
}

@Test
func appleMusicRawDataReplyDecodesToALoadableCover() async throws {
  let cover = try png(width: 600, height: 600)
  let hex = cover.map { String(format: "%02X", $0) }.joined()

  #expect(MusicScriptRunner.parseRawData("«data PNGf\(hex)»\n") == cover)
  #expect(MusicScriptRunner.parseRawData("«data JPEG\(hex.lowercased())»") == cover)
  let image = try #require(await ArtworkLoader.load(.appleMusic(cover)))
  #expect(image.width <= 256 && image.height <= 256)

  // Only a bounded thumbnail of the cover is kept.
  let thumbnail = try #require(ArtworkLoader.thumbnailJPEG(from: cover))
  let decoded = try #require(ArtworkLoader.decode(thumbnail))
  #expect(decoded.width == 256 && decoded.height == 256)
  #expect(thumbnail.starts(with: [0xFF, 0xD8]), "JPEG")
  #expect(ArtworkLoader.thumbnailJPEG(from: Data("not an image".utf8)) == nil)

  for malformed in [
    "", "missing value", "«data PNGf»", "«data PNGf\(hex)", "data PNGf\(hex)»",
    "«data PNGf\(hex)0»", "«data PNGfZZ\(hex)»", "«class PNGf\(hex)»",
  ] {
    #expect(MusicScriptRunner.parseRawData(malformed) == nil)
  }
}

private actor ArtworkFetchLog {
  private(set) var trackIDs: [String] = []
  func record(_ trackID: String) { trackIDs.append(trackID) }
}

@MainActor
@Test
func appleMusicCoverIsReadOncePerTrackAndRetriedOnlyAfterFailures() async throws {
  let suite = "AppleMusicArtwork-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let cover = try png(width: 64, height: 64)
  let log = ArtworkFetchLog()
  let controller = MusicController(
    defaults: defaults,
    artworkPaletteLoader: { _ in nil },
    nativePlayer: .fake(artwork: { trackID in
      await log.record(trackID)
      switch trackID {
      case "A": return .artwork(cover)
      case "B": return .unavailable
      default: return .failed
      }
    })
  )

  func poll(_ trackID: String) async throws {
    let snapshot = try #require(
      MusicScriptRunner.parse(appleMusicOutput(trackID: trackID), source: .appleMusic)
    )
    controller.apply(MusicQueryBatch(snapshots: [snapshot], errorMessage: nil))
    #expect(await waitUntil { !controller.isLoadingAppleMusicArtwork })
  }

  try await poll("A")
  #expect(controller.nowPlaying?.artworkSource == .appleMusic(cover))
  try await poll("A")
  #expect(controller.nowPlaying?.artworkSource == .appleMusic(cover), "Later polls keep the cover")

  // A track without a cover keeps the fallback and is not asked again.
  try await poll("B")
  #expect(controller.nowPlaying?.artworkSource == nil)
  try await poll("B")

  // Failures are retried on later polls, but only a bounded number of times.
  for _ in 0..<5 { try await poll("C") }
  #expect(controller.nowPlaying?.artworkSource == nil)

  let expected = ["A", "B"] + Array(repeating: "C", count: MusicController.appleMusicArtworkAttempts)
  #expect(await log.trackIDs == expected)
}

@Test
func scriptRepliesLargerThanThePipeBufferDoNotStallUntilTimeout() async {
  // 16 × 2^16 = 1 MiB, well past the 64 KiB pipe buffer.
  let script = """
    set s to "0123456789ABCDEF"
    repeat 16 times
      set s to s & s
    end repeat
    return s
    """
  let started = Date()
  let result = await MusicScriptRunner.run(script: script, timeout: 20, outputLimit: 2_000_000)
  #expect(!result.timedOut)
  #expect(result.exitStatus == 0)
  #expect(result.output.trimmingCharacters(in: .newlines).utf8.count == 1_048_576)
  #expect(Date().timeIntervalSince(started) < 15)

  let capped = await MusicScriptRunner.run(script: script, timeout: 20, outputLimit: 100_000)
  #expect(!capped.timedOut)
  #expect(capped.outputTooLarge)
  #expect(capped.output.isEmpty)
}
