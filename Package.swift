// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentDots",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "AgentDots", path: "Sources/AgentDots", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
