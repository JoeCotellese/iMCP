// swift-tools-version: 6.0
// ABOUTME: Swift package for iMCP's bridge to Apple's private ReminderKit framework.
// ABOUTME: Ships the ReminderKitBridge library (Foundation only), the rkprobe live probes, and their tests.

import PackageDescription

let package = Package(
    name: "ReminderKitBridge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ReminderKitBridge", targets: ["ReminderKitBridge"])
    ],
    targets: [
        .target(name: "ReminderKitBridge"),
        .executableTarget(
            name: "rkprobe",
            dependencies: ["ReminderKitBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
