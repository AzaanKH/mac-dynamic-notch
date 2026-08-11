// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "NotchRouter",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "NotchRouter", targets: ["NotchRouterApp"]),
    .executable(name: "notchctl", targets: ["NotchCLI"]),
    .executable(
      name: "notchrouter-browser-host",
      targets: ["NotchBrowserHost"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/getsentry/sentry-cocoa-binaries",
      exact: "9.25.0"
    ),
    .package(
      url: "https://github.com/sparkle-project/Sparkle",
      exact: "2.9.5"
    ),
  ],
  targets: [
    .target(
      name: "NotchRouterCore"
    ),
    .executableTarget(
      name: "NotchRouterApp",
      dependencies: [
        "NotchRouterCore",
        .product(name: "Sentry-Static", package: "sentry-cocoa-binaries"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-rpath",
          "-Xlinker", "@executable_path/../Frameworks",
        ])
      ]
    ),
    .executableTarget(
      name: "NotchCLI",
      dependencies: ["NotchRouterCore"]
    ),
    .executableTarget(
      name: "NotchBrowserHost",
      dependencies: ["NotchRouterCore"]
    ),
    .testTarget(
      name: "NotchRouterCoreTests",
      dependencies: ["NotchRouterCore"]
    ),
    .testTarget(
      name: "NotchRouterAppTests",
      dependencies: ["NotchRouterApp"]
    ),
  ]
)
