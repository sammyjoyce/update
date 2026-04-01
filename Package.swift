// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Update",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "update", targets: ["update"]),
        .library(name: "UpdateCore", targets: ["UpdateCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "update",
            dependencies: [
                "UpdateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "UpdateCore"
        ),
        .testTarget(
            name: "UpdateCoreTests",
            dependencies: ["UpdateCore"],
            path: "Tests/UpdateCoreTests"
        ),
    ]
)
