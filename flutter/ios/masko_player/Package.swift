// swift-tools-version: 5.9
// masko_player for apps that build their Flutter plugins with Swift Package
// Manager. The Swift player (vendor/MaskoPlayer) and its engine with dav1d
// (vendor/MaskoPlayerFFI.xcframework) are the copies scripts/build-flutter.sh
// makes, the same ones masko_player.podspec builds with CocoaPods.
import PackageDescription

let package = Package(
    name: "masko_player",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "masko-player", targets: ["masko_player"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(name: "MaskoPlayerFFI", path: "vendor/MaskoPlayerFFI.xcframework"),
        .target(
            name: "MaskoPlayer",
            dependencies: ["MaskoPlayerFFI"],
            path: "vendor/MaskoPlayer",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "masko_player",
            dependencies: [
                "MaskoPlayer",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ]
        ),
    ]
)
