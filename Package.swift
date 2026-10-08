// swift-tools-version:5.10
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency=targeted"),
]

let package = Package(
    name: "ImageWriterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImageWriterCore", targets: ["ImageWriterCore"]),
    ],
    targets: [
        .target(
            name: "ImageWriterCore",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ImageWriterCoreTests",
            dependencies: ["ImageWriterCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageVersions: [.v5]
)
