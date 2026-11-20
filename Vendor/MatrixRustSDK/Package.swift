// swift-tools-version: 5.9
// Matrix Rust SDK compiled for macOS. Regenerate with Scripts/build-sdk.sh.
import PackageDescription

let package = Package(
    name: "MatrixRustSDK",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MatrixRustSDK", targets: ["MatrixRustSDK"]),
    ],
    targets: [
        .binaryTarget(name: "MatrixSDKFFI", path: "MatrixSDKFFI.xcframework"),
        .target(
            name: "MatrixRustSDK",
            dependencies: ["MatrixSDKFFI"],
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
