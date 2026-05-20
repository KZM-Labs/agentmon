// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Agentmon",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Agentmon",
            path: "Sources/Agentmon"
        )
    ]
)
