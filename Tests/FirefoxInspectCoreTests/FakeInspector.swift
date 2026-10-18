import Foundation

@testable import FirefoxInspectCore

/// In-memory `BrowserInspector`. Every fixture is invented, and every host is
/// `example.com` or a `.invalid` domain, which can never resolve. The suite never starts
/// a browser and never touches a real Firefox profile.
final class FakeInspector: BrowserInspector, @unchecked Sendable {
    var browserStatus = BrowserStatus(
        executablePath: "/fake/firefox", executableExists: true, isRunning: false, version: nil)
    var openedURLs: [String] = []
    var console: [ConsoleEntry] = []
    var network: [NetworkEntry] = []
    var elementsResult = ElementsResult(matchCount: 1, html: "<h1>Fixture</h1>", isTruncated: false)
    var selectors: [String] = []
    var clearedConsole = false
    var failure: InspectError?

    func status() async -> BrowserStatus { browserStatus }

    func open(url: String) async throws -> PageInfo {
        if let failure { throw failure }
        openedURLs.append(url)
        return PageInfo(url: url, title: "Fixture page")
    }

    func elements(selector: String, characterLimit: Int) async throws -> ElementsResult {
        selectors.append(selector)
        return elementsResult
    }

    func consoleMessages(clear: Bool) async throws -> [ConsoleEntry] {
        clearedConsole = clear
        return console
    }

    func networkRequests() async throws -> [NetworkEntry] { network }

    func responseBody(requestID: String, characterLimit: Int) async throws -> ResponseBody {
        ResponseBody(text: "body of \(requestID)", isBase64: false, isTruncated: false)
    }

    func storage() async throws -> StorageSnapshot {
        StorageSnapshot(
            cookies: [
                CookieInfo(
                    name: "session", domain: "example.com", path: "/", value: "fixture",
                    isHTTPOnly: true, isSecure: true)
            ], local: ["theme": "dark"], session: [:])
    }

    func screenshot() async throws -> String { "AAAA" }
}
