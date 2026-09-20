// swift-tools-version: 6.1
import Foundation
import PackageDescription

let package = Package(
    name: "GhosttySnapshotTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "GhosttyKit", path:
        ProcessInfo.processInfo.environment["CRAFT_GHOSTTY_PACKAGE"] ?? "../.build/ghostty-native/package")],
    targets: [.testTarget(name: "GhosttySnapshotTests", dependencies: [
        .product(name: "GhosttyTerminal", package: "GhosttyKit"),
        .product(name: "GhosttyKit", package: "GhosttyKit"),
    ])]
)
