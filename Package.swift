// swift-tools-version:5.9
// For the tests (`swift test`) and for opening the project in Xcode. The app itself is built by
// build.sh, which puts the two programs into ClaudeNotch.app (for both kinds of Mac when asked).
import PackageDescription

// SwiftPM's build system now and then leaves Swift Testing's macros out of a test file's compile
// ("plugin for module 'TestingMacros' not found"). Pointing at them by hand makes it every time; a
// folder that isn't there is skipped.
let testingMacros = [
    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing",
].flatMap { ["-plugin-path", $0] }

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeNotch", path: "Sources/App"),
        .executableTarget(name: "claude-notch-hook", path: "Sources/Hook"),
        .testTarget(name: "ClaudeNotchTests", dependencies: ["ClaudeNotch"], path: "Tests/ClaudeNotchTests",
                    swiftSettings: [.unsafeFlags(testingMacros)]),
    ]
)
