// swift-tools-version: 5.10
//
// PlatenCore is the platform-neutral heart of Platen Reader: reading book
// files, parsing EPUB packages, detecting DRM, fixing up odd files and storing
// reading positions. It has no AppKit, UIKit or WebKit dependency, so the macOS
// app and the later iOS app share it unchanged, and it can be unit-tested with
// `swift test` alone.

import PackageDescription

let package = Package(
    name: "PlatenCore",
    defaultLocalization: "en-GB",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PlatenCore", targets: ["PlatenCore"]),
    ],
    targets: [
        .target(name: "PlatenCore", resources: [.process("Resources")]),
        .testTarget(name: "PlatenCoreTests", dependencies: ["PlatenCore"]),
    ]
)
