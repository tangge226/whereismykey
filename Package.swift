// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhereKey",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhereKeyCore", targets: ["WhereKeyCore"]),
        .executable(name: "WhereKeyApp", targets: ["WhereKeyApp"]),
        .executable(name: "wherekey", targets: ["wherekey"]),
    ],
    targets: [
        .target(
            name: "WhereKeyCore",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
            ]
        ),
        .executableTarget(
            name: "WhereKeyApp",
            dependencies: ["WhereKeyCore"],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "wherekey",
            dependencies: ["WhereKeyCore"],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
        .testTarget(
            name: "WhereKeyCoreTests",
            dependencies: ["WhereKeyCore"],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
    ]
)
