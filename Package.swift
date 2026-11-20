// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Huddle",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "Vendor/MatrixRustSDK"),
        // Updates: Check for Updates, and installing them. Bundled into the app by build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
        // Observation for macOS 13: Point-Free's backport, which hands over to Apple's own on
        // macOS 14 and later. Views that read the app's state wrap their content in
        // WithPerceptionTracking, which is how macOS 13 notices what they read.
        .package(url: "https://github.com/pointfreeco/swift-perception", from: "1.3.0"),
        // Perception's own way of reporting state a view reads without tracking it; Dev builds
        // print those reports (PerceptionCheck.swift).
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "Huddle",
            dependencies: [
                .product(name: "MatrixRustSDK", package: "MatrixRustSDK"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Perception", package: "swift-perception"),
                .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
            ],
            path: "Sources/Huddle",
            // Sparkle.framework goes in the app's Frameworks folder (Scripts/build-app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
