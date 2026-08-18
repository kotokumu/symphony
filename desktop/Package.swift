// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SymphonyDesktop",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "SymphonyDesktop", targets: ["SymphonyDesktop"])
  ],
  targets: [
    .executableTarget(name: "SymphonyDesktop"),
    .testTarget(
      name: "SymphonyDesktopTests",
      dependencies: ["SymphonyDesktop"]
    ),
  ]
)
