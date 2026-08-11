import Darwin
import Foundation
import NotchRouterCore

final class SingleInstanceGuard: @unchecked Sendable {
  static let showRequest = Notification.Name(
    "com.notchrouter.app.show-request"
  )

  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }

  static func acquire(
    at lockURL: URL = AppPaths.applicationSupportDirectory
      .appendingPathComponent("instance.lock")
  ) throws -> SingleInstanceGuard? {
    try FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let descriptor = open(
      lockURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw posixError() }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      close(descriptor)
      if lockError == EWOULDBLOCK || lockError == EAGAIN {
        return nil
      }
      throw posixError(lockError)
    }

    return SingleInstanceGuard(descriptor: descriptor)
  }

  private static func posixError(_ code: Int32 = errno) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(code),
      userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
    )
  }
}
