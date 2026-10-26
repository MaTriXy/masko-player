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
let releaseURL = "https://github.com/masko-ai/masko-player/releases/download/0.1.5/MaskoPlayerFFI.xcframework.zip"
let releaseChecksum = "a909ed3ac5ec86d5774f659a4ed176c6aed607b227876931926c9d7e34b566c0"

let localEngine = "apple/MaskoPlayerFFI.xcframework"
let engine: Target =
    FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + localEngine + "/Info.plist")
    ? .binaryTarget(name: "MaskoPlayerFFI", path: localEngine)
    : .binaryTarget(name: "MaskoPlayerFFI", url: releaseURL, checksum: releaseChecksum)

let package = Package(
    name: "MaskoPlayer",
    platforms: [.iOS(.v15), .macOS(.v13), .macCatalyst(.v15), .visionOS(.v1)],
    products: [
        .library(name: "MaskoPlayer", targets: ["MaskoPlayer"])
    ],
    targets: [
        engine,
        .target(
            name: "MaskoPlayer",
            dependencies: ["MaskoPlayerFFI"],
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
