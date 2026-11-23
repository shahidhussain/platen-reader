// swift-tools-version: 5.10
//
// PlatenCore is the platform-neutral heart of Platen Reader: reading book
// files, parsing EPUB packages, detecting DRM, fixing up odd files and storing
// reading positions. It has no AppKit, UIKit or WebKit dependency, so the macOS
// app and the later iOS app share it unchanged, and it can be unit-tested with
// `swift test` alone.
//
// Kokoro is read aloud's natural voice (Kokoro-82M on Accelerate), a module
// of its own so that it is compiled with optimisation even in Debug builds:
// unoptimised it runs about sixty times slower than real time allows.

import PackageDescription

let package = Package(
    name: "PlatenCore",
    defaultLocalization: "en-GB",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PlatenCore", targets: ["PlatenCore", "Kokoro"]),
    ],
    targets: [
        .target(name: "PlatenCore", resources: [.process("Resources")]),
        .target(name: "Kokoro", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "PlatenCoreTests", dependencies: ["PlatenCore"]),
        .testTarget(name: "KokoroTests", dependencies: ["Kokoro"]),
    ]
)
