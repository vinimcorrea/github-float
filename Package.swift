// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitHubFloat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "GitHubFloat", path: "Sources/GitHubFloat")
    ]
)
