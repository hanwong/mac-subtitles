// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HeyMac",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")
    ],
    targets: [
        .executableTarget(
            name: "HeyMac",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/HeyMac"
        ),
        .testTarget(name: "HeyMacTests", dependencies: ["HeyMac"], path: "Tests/HeyMacTests"),
    ]
)
