// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LiveSubtitles",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "LiveSubtitles", path: "Sources/LiveSubtitles")
    ]
)
