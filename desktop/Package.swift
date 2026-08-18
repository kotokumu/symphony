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
    .target(name: "SymphonyDesktopCore"),
    .target(
      name: "SymphonyDesktopInfrastructure",
      dependencies: ["SymphonyDesktopCore"]
    ),
    .executableTarget(
      name: "SymphonyDesktop",
      dependencies: ["SymphonyDesktopCore", "SymphonyDesktopInfrastructure"]
    ),
    .testTarget(
      name: "SymphonyDesktopTests",
      dependencies: [
        "SymphonyDesktop",
        "SymphonyDesktopCore",
        "SymphonyDesktopInfrastructure",
      ]
    ),
  ]
)
