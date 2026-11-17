// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Huddle",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/MatrixRustSDK"),
    ],
    targets: [
        .executableTarget(
            name: "Huddle",
            dependencies: [
                .product(name: "MatrixRustSDK", package: "MatrixRustSDK"),
            ],
            path: "Sources/Huddle"
        ),
    ]
)
