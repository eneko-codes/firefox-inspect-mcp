import Foundation
import Testing

@testable import FirefoxInspectCore

@Suite("Arguments and configuration")
struct SupportTests {

    @Test("Only http and https are accepted; a host and port is not a scheme")
    func urlValidation() throws {
        #expect(try Arguments.validatedWebURL("http://example.com", argument: "url") == "http://example.com")
        #expect(try Arguments.validatedWebURL("example.com:8080/x", argument: "url") == "https://example.com:8080/x")
        #expect(throws: InspectError.self) { try Arguments.validatedWebURL("ftp://example.com", argument: "url") }
        #expect(throws: InspectError.self) { try Arguments.validatedWebURL("JavaScript:1", argument: "url") }
    }

    @Test("A numeric argument is clamped, not rejected")
    func clamping() throws {
        let arguments = Arguments(["limit": .int(99_999)])
        #expect(try arguments.int("limit", default: 10, in: 1...500) == 500)
        #expect(throws: InspectError.self) { try Arguments(["limit": .string("many")]).int("limit", default: 10, in: 1...500) }
    }

    @Test("An unsubstituted manifest placeholder never becomes the Firefox path")
    func placeholderIgnored() {
        let fallback = Configuration().firefoxPath
        #expect(Configuration.parse(["--firefox-path", "${user_config.firefox_path}"]).firefoxPath == fallback)
        #expect(Configuration.parse(["--firefox-path", "/opt/firefox"]).firefoxPath == "/opt/firefox")
        #expect(Configuration.parse(["--unknown", "x"]).firefoxPath == fallback)
    }

    @Test("Only a loopback BiDi endpoint is accepted from Firefox's startup output")
    func endpointParsing() {
        typealias Announcement = FirefoxProcess.Announcement
        #expect(Announcement.endpoint(in: "WebDriver BiDi listening on ws://127.0.0.1:41234\n")?.port == 41234)
        #expect(Announcement.endpoint(in: "WebDriver BiDi listening on ws://203.0.113.9:9222") == nil)
        #expect(Announcement.endpoint(in: "starting up") == nil)
    }
}

@Suite("Diagnostics")
struct DiagnosticsTests {
    private enum SampleError: Error { case rejected(url: String) }

    @Test("An enum error is reported by case, never by its payload")
    func payloadStaysOut() {
        let kind = Diagnostics.kind(of: SampleError.rejected(url: "https://example.com/?token=abc"))
        #expect(kind.hasSuffix("SampleError.rejected"))
        #expect(!kind.contains("token"))
        #expect(!Diagnostics.kind(of: InspectError.navigationFailed(code: "x")).contains("x)"))
    }

    @Test("A tool name that is not a plain identifier cannot reach the log")
    func toolNameSanitised() {
        #expect(Diagnostics.toolName("open_url") == "open_url")
        #expect(Diagnostics.toolName("evil\nfatal forged line") == "invalid")
    }
}

@Suite("Release")
struct ReleaseTests {

    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The server is built from the system's own frameworks and nothing else. A dependency
    /// is a decision for the owner, so adding one has to break this test first.
    @Test("The package declares no third-party dependency")
    func noDependencies() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!package.contains(".package("), "Package.swift declares a dependency")
        #expect(!package.contains(".product("))
    }
}
