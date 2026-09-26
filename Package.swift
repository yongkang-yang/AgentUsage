// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [.macOS(.v14)],
    targets: [
        // Credential discovery, usage fetching and parsing per agent. No UI, so it can be tested.
        .target(
            name: "AgentUsageKit",
            path: "Sources/AgentUsageKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Menu bar app: status item, usage panel, settings.
        .executableTarget(
            name: "AgentUsage",
            dependencies: ["AgentUsageKit"],
            path: "Sources/AgentUsage",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentUsageKitTests",
            dependencies: ["AgentUsageKit"],
            path: "Tests/AgentUsageKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
