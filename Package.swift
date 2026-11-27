// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Huddle",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/MatrixRustSDK"),
        // Updates: Check for Updates, and installing them. Bundled into the app by build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "Huddle",
            dependencies: [
                .product(name: "MatrixRustSDK", package: "MatrixRustSDK"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Huddle",
            // Sparkle.framework goes in the app's Frameworks folder (Scripts/build-app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // swift test: what can be checked without a server, the security fixes above all.
        // Tests use temporary folders only: run outside the app, Huddle takes itself for the
        // release build, whose data is the user's.
        .testTarget(
            name: "HuddleTests",
            dependencies: ["Huddle", .product(name: "MatrixRustSDK", package: "MatrixRustSDK")],
            path: "Tests/HuddleTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
