// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LiveSubtitles",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")
    ],
    targets: [
        .executableTarget(
            name: "LiveSubtitles",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/LiveSubtitles"
        )
    ]
)
