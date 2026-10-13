// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RtechWhisperKit",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0")
    ],
    products: [
        .library(name: "RtechWhisperKit", targets: ["RtechWhisperKit"])
    ],
    targets: [
        .target(name: "RtechWhisperKit"),
        .testTarget(
            name: "RtechWhisperKitTests",
            dependencies: ["RtechWhisperKit"],
            // Read from disk by path in SyncModelTests, not bundled.
            exclude: ["Fixtures"]
        )
    ]
)
