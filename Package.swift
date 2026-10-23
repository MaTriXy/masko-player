// swift-tools-version:5.9
// The MaskoPlayer Swift package: the Masko engine (MaskoPlayerFFI, built by
// scripts/build-apple.sh) and the player around it, for iPhone, iPad and Mac.
import PackageDescription

let package = Package(
    name: "MaskoPlayer",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "MaskoPlayer", targets: ["MaskoPlayer"])
    ],
    targets: [
        .binaryTarget(name: "MaskoPlayerFFI", path: "apple/MaskoPlayerFFI.xcframework"),
        .target(
            name: "MaskoPlayer",
            dependencies: ["MaskoPlayerFFI"],
            path: "apple/Sources/MaskoPlayer"
        ),
        .testTarget(
            name: "MaskoPlayerTests",
            dependencies: ["MaskoPlayer"],
            path: "apple/Tests/MaskoPlayerTests",
            resources: [.copy("Clips")]
        ),
    ]
)
