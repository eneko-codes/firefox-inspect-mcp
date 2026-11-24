// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "firefox-inspect-mcp",
    platforms: [.macOS(.v15)],
    targets: [
        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        .target(name: "FirefoxInspectCore"),
        .executableTarget(
            name: "firefox-inspect-mcp",
            dependencies: ["FirefoxInspectCore"]
        ),
        .testTarget(name: "FirefoxInspectCoreTests", dependencies: ["FirefoxInspectCore"]),
    ]
)
