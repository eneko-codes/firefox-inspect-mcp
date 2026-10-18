// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "firefox-inspect-mcp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        .target(
            name: "FirefoxInspectCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "firefox-inspect-mcp",
            dependencies: ["FirefoxInspectCore"]
        ),
        .testTarget(name: "FirefoxInspectCoreTests", dependencies: ["FirefoxInspectCore"]),
    ]
)
