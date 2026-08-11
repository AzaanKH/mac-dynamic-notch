import Foundation
import Sentry

enum CrashReporter {
  static func start(bundle: Bundle = .main) {
    guard
      let dsn = bundle.object(forInfoDictionaryKey: "SentryDSN") as? String,
      !dsn.isEmpty
    else {
      return
    }

    let bundleIdentifier = bundle.bundleIdentifier ?? "com.notchrouter.app"
    let version = bundle.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "unknown"
    let build = bundle.object(
      forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "unknown"
    let environment = bundle.object(
      forInfoDictionaryKey: "SentryEnvironment"
    ) as? String ?? "production"

    SentrySDK.start { options in
      options.dsn = dsn
      options.environment = environment
      options.releaseName = "\(bundleIdentifier)@\(version)+\(build)"
      options.sendDefaultPii = false
      options.debug = false
    }
  }
}
