// swift-tools-version:5.9
// A small Mac app around MaskoPlayer: `swift run MaskoPlayerDemo <delivery.json>`.
import PackageDescription

let package = Package(
    name: "MaskoPlayerDemo",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "MaskoPlayer", path: "../../..")],
    targets: [
        .executableTarget(
            name: "MaskoPlayerDemo",
            dependencies: [.product(name: "MaskoPlayer", package: "MaskoPlayer")]
        )
    ]
)
