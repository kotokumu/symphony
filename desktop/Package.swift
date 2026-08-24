// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SymphonyDesktop",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "SymphonyDesktop", targets: ["SymphonyDesktop"]),
    .executable(name: "SymphonyCredentialBroker", targets: ["SymphonyCredentialBroker"]),
    .executable(
      name: "SymphonyCredentialStoreSmoke",
      targets: ["SymphonyCredentialStoreSmoke"]
    ),
  ],
  targets: [
    .target(name: "SymphonyDesktopCore"),
    .target(name: "SymphonyCredentialBrokerProtocol"),
    .target(
      name: "SymphonyCredentialBrokerKit",
      dependencies: ["SymphonyCredentialBrokerProtocol"],
      linkerSettings: [
        .linkedFramework("CryptoKit"),
        .linkedFramework("LocalAuthentication"),
        .linkedFramework("Network"),
        .linkedFramework("Security"),
      ]
    ),
    .executableTarget(
      name: "SymphonyCredentialBroker",
      dependencies: ["SymphonyCredentialBrokerKit", "SymphonyCredentialBrokerProtocol"]
    ),
    .executableTarget(
      name: "SymphonyCredentialStoreSmoke",
      dependencies: ["SymphonyCredentialBrokerKit"]
    ),
    .target(
      name: "SymphonyDesktopInfrastructure",
      dependencies: ["SymphonyDesktopCore", "SymphonyCredentialBrokerProtocol"]
    ),
    .executableTarget(
      name: "SymphonyDesktop",
      dependencies: ["SymphonyDesktopCore", "SymphonyDesktopInfrastructure"],
      linkerSettings: [.linkedFramework("IOKit")]
    ),
    .testTarget(
      name: "SymphonyDesktopTests",
      dependencies: [
        "SymphonyDesktop",
        "SymphonyCredentialBrokerKit",
        "SymphonyCredentialBrokerProtocol",
        "SymphonyDesktopCore",
        "SymphonyDesktopInfrastructure",
      ]
    ),
  ]
)
