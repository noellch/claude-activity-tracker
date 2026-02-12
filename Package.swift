// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeActivityTracker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeActivityTracker",
            path: "ClaudeActivityTracker"
        )
    ]
)
