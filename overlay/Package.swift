// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        // Library: all app logic — importable by tests
        .target(
            name: "ClaudeMonitorLib",
            path: "Sources/ClaudeMonitor"
        ),
        // Executable: thin entry point only
        .executableTarget(
            name: "ClaudeMonitor",
            dependencies: ["ClaudeMonitorLib"],
            path: "Sources/ClaudeMonitorMain"
        ),
        // Tests
        .testTarget(
            name: "ClaudeMonitorTests",
            dependencies: ["ClaudeMonitorLib"],
            path: "Tests/ClaudeMonitorTests"
        )
    ]
)
