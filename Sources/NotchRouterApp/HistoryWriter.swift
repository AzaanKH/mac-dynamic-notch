import Dispatch
import Foundation
import NotchRouterCore

/// Keeps at most one pending snapshot while a serial utility queue writes to disk.
/// The lock protects the pending snapshot, drain state, and flush continuations.
final class HistoryWriter<Snapshot: Encodable & Sendable>: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.notchrouter.history-writer", qos: .utility)
  private let lock = NSLock()
  private var pending: Snapshot?
  private var isDraining = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let write: @Sendable (Snapshot) throws -> Void
  private let onError: @Sendable (Error) -> Void

  init(
    storageURL: URL,
    onError: @escaping @Sendable (Error) -> Void = {
      NSLog("NotchRouter could not save history: \($0)")
    }
  ) {
    self.write = { snapshot in
      let directory = storageURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path
      )
      let data = try ActivityCoding.makeEncoder(prettyPrinted: true).encode(snapshot)
      try data.write(to: storageURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: storageURL.path
      )
    }
    self.onError = onError
  }

  init(
    write: @escaping @Sendable (Snapshot) throws -> Void,
    onError: @escaping @Sendable (Error) -> Void
  ) {
    self.write = write
    self.onError = onError
  }

  func submit(_ snapshot: Snapshot) {
    lock.lock()
    pending = snapshot
    let shouldStart = !isDraining
    isDraining = true
    lock.unlock()
    if shouldStart {
      queue.async { self.drain() }
    }
  }

  /// Waits without blocking the caller's actor, including when the last write failed.
  func flush() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if isDraining {
        waiters.append(continuation)
        lock.unlock()
      } else {
        lock.unlock()
        continuation.resume()
      }
    }
  }

  private func drain() {
    while true {
      lock.lock()
      guard let snapshot = pending else {
        isDraining = false
        let completedWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in completedWaiters { waiter.resume() }
        return
      }
      pending = nil
      lock.unlock()
      do {
        try write(snapshot)
      } catch {
        onError(error)
      }
    }
  }
}
