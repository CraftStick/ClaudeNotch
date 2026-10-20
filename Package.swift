// swift-tools-version:5.9
// For the tests (`swift test`) and for opening the project in Xcode. The app itself is built by
// build.sh, which puts the two programs into ClaudeNotch.app (for both kinds of Mac when asked).
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeNotch", path: "Sources/App"),
        .executableTarget(name: "claude-notch-hook", path: "Sources/Hook"),
        .testTarget(name: "ClaudeNotchTests", dependencies: ["ClaudeNotch"], path: "Tests/ClaudeNotchTests"),
    ]
)
