// swift-tools-version:5.9
// The MaskoPlayer Swift package: the Masko engine (MaskoPlayerFFI) and the
// player around it, for iPhone, iPad, Mac, Mac Catalyst and Apple Vision Pro.
import Foundation
import PackageDescription

// The engine is a binary target. In a clone of this repository with the
// engine built (scripts/build-apple.sh), it is that local xcframework. An app
// that adds this package by URL gets no build there (the xcframework is
// git-ignored), so it downloads the release zip; scripts/release-apple.sh
// writes its URL and checksum here.
let releaseURL = "https://github.com/masko-ai/masko-player/releases/download/0.1.9/MaskoPlayerFFI.xcframework.zip"
let releaseChecksum = "92db2840ccb9d71dfef85e46076feb8ff0440d63f2e648542af4047915751c4b"

let localEngine = "apple/MaskoPlayerFFI.xcframework"
let engine: Target =
    FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + localEngine + "/Info.plist")
    ? .binaryTarget(name: "MaskoPlayerFFI", path: localEngine)
    : .binaryTarget(name: "MaskoPlayerFFI", url: releaseURL, checksum: releaseChecksum)

// dav1d decodes AV1 on devices without an AV1 decoder. Like the engine, it
// is the local xcframework when built (scripts/build-dav1d-apple.sh), else its
// release zip; scripts/release-apple.sh writes that zip's URL and checksum.
let dav1dReleaseURL = "https://github.com/masko-ai/masko-player/releases/download/0.1.9/dav1d.xcframework.zip"
let dav1dReleaseChecksum = "3047f6cfd96c639b10407599ac76613adc74431870ad5659ee27c98d62598fda"

let localDav1d = "apple/dav1d.xcframework"
let dav1d: Target =
    FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + localDav1d + "/Info.plist")
    ? .binaryTarget(name: "Dav1d", path: localDav1d)
    : .binaryTarget(name: "Dav1d", url: dav1dReleaseURL, checksum: dav1dReleaseChecksum)

let package = Package(
    name: "MaskoPlayer",
    platforms: [.iOS(.v15), .macOS(.v13), .macCatalyst(.v15), .visionOS(.v1)],
    products: [
        .library(name: "MaskoPlayer", targets: ["MaskoPlayer"])
    ],
    targets: [
        engine,
        dav1d,
        .target(
            name: "MaskoPlayer",
            dependencies: ["MaskoPlayerFFI", "Dav1d"],
            path: "apple/Sources/MaskoPlayer",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "MaskoPlayerTests",
            dependencies: ["MaskoPlayer"],
            path: "apple/Tests/MaskoPlayerTests",
            resources: [.copy("Clips")]
        ),
    ]
)
