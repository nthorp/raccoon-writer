// swift-tools-version:5.10
// Throwaway T01 spike. Deliberately not part of the root package.
import PackageDescription

let package = Package(
    name: "AuthopenSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AuthopenSpike",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency=targeted")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
