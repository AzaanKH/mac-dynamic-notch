import Dispatch
import Foundation
import Testing
@testable import NotchRouterApp

private final class WriteRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Int] = []
  private var errorCount = 0
  private var ranOnMainThread = false

  func record(_ value: Int) {
    lock.withLock {
      recorded.append(value)
      ranOnMainThread = ranOnMainThread || Thread.isMainThread
    }
  }

  func recordError() { lock.withLock { errorCount += 1 } }
  var values: [Int] { lock.withLock { recorded } }
  var errors: Int { lock.withLock { errorCount } }
  var usedMainThread: Bool { lock.withLock { ranOnMainThread } }
}

@MainActor
@Test
func historyWritesCoalesceWhileBusyAndFlushTheLatestSnapshot() async {
  let recorder = WriteRecorder()
  let gate = DispatchSemaphore(value: 0)
  let (started, continuation) = AsyncStream<Void>.makeStream()
  let writer = HistoryWriter<Int>(write: { value in
    recorder.record(value)
    if value == 1 {
      continuation.yield(())
      gate.wait()
    }
  }, onError: { _ in recorder.recordError() })
  writer.submit(1)
  var iterator = started.makeAsyncIterator()
  _ = await iterator.next()
  for value in 2...100 { writer.submit(value) }
  async let flushed: Void = writer.flush()
  gate.signal()
  await flushed
  #expect(recorder.values == [1, 100])
  #expect(!recorder.usedMainThread)
  #expect(recorder.errors == 0)
  continuation.finish()
}

@Test
func historyWriteFailureDoesNotStrandFlushOrLaterSaves() async {
  let recorder = WriteRecorder()
  let writer = HistoryWriter<Int>(write: { value in
    if value == 1 { throw CocoaError(.fileWriteNoPermission) }
    recorder.record(value)
  }, onError: { _ in recorder.recordError() })
  writer.submit(1)
  await writer.flush()
  #expect(recorder.errors == 1)
  writer.submit(2)
  await writer.flush()
  #expect(recorder.values == [2])
}

@Test
func historyWriterPreservesPrivatePermissionsAndExternalJSON() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("history.json")
  let writer = HistoryWriter<[String: Int]>(storageURL: url)
  writer.submit(["latest_sequence": 42])
  await writer.flush()
  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Int]
  #expect(json == ["latest_sequence": 42])
  let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
  let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
  #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
