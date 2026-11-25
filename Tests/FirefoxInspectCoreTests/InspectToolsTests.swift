import Foundation
import Testing

@testable import FirefoxInspectCore

@Suite("Tools")
struct InspectToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:], on inspector: FakeInspector = FakeInspector()
    ) async -> (text: String, isError: Bool, content: [ToolOutput.Block]) {
        let result = await InspectTools(inspector: inspector).handle(
            .init(name: name, arguments: arguments))
        return (result.text, result.isError, result.content)
    }

    @Test("Every advertised tool is routed, and nothing else is")
    func catalogueMatchesRouting() async {
        let names = Set(ToolCatalog.all().map(\.name))
        #expect(names.count == 8)
        let unknown = await call("run_javascript")
        #expect(unknown.isError)
        #expect(unknown.text.contains("not a tool of this server"))
    }

    @Test("open_url refuses schemes that are not web pages, without touching the browser")
    func refusesUnsafeSchemes() async {
        let inspector = FakeInspector()
        for url in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi"] {
            let reply = await call("open_url", ["url": .string(url)], on: inspector)
            #expect(reply.isError)
        }
        #expect(inspector.openedURLs.isEmpty)
    }

    @Test("A bare host becomes https")
    func bareHostIsHTTPS() async {
        let inspector = FakeInspector()
        let reply = await call("open_url", ["url": .string("example.com/path")], on: inspector)
        #expect(!reply.isError)
        #expect(inspector.openedURLs == ["https://example.com/path"])
    }

    @Test("page_elements defaults to the whole document")
    func elementsDefaultSelector() async {
        let inspector = FakeInspector()
        _ = await call("page_elements", on: inspector)
        #expect(inspector.selectors == ["html"])
    }

    @Test("console_messages filters by level and lists the oldest entries first")
    func consoleFilter() async {
        let inspector = FakeInspector()
        let moment = Date(timeIntervalSince1970: 0)
        inspector.console = (1...5).map {
            ConsoleEntry(level: $0 % 2 == 0 ? "error" : "info", source: "console", text: "m\($0)", timestamp: moment)
        }
        let reply = await call("console_messages", ["level": .string("error"), "limit": .int(1), "clear": .bool(true)], on: inspector)
        #expect(reply.text.contains("m2"))
        #expect(!reply.text.contains("m4"))
        #expect(reply.text.hasPrefix("Showing 1–1 of 2 console messages. The history was cleared, so the rest cannot be read again."))
        #expect(inspector.clearedConsole)
    }

    @Test("network_requests filters by URL and hides headers unless asked")
    func networkFilter() async {
        let inspector = FakeInspector()
        inspector.network = [
            NetworkEntry(id: "1", method: "GET", url: "https://example.com/app.js", status: 200,
                requestHeaders: [HTTPHeader(name: "Accept", value: "*/*")]),
            NetworkEntry(id: "2", method: "GET", url: "https://example.com/style.css", status: 404),
        ]
        let plain = await call("network_requests", ["url_contains": .string("app.js")], on: inspector)
        #expect(plain.text.contains("app.js"))
        #expect(!plain.text.contains("style.css"))
        #expect(!plain.text.contains("Accept"))

        let detailed = await call("network_requests", ["include_headers": .bool(true)], on: inspector)
        #expect(detailed.text.contains("Accept: */*"))
    }

    @Test("A failed request is reported as failed, not as pending")
    func failedRequest() async {
        let inspector = FakeInspector()
        inspector.network = [NetworkEntry(id: "1", method: "GET", url: "https://nothing.invalid/", failure: "NS_ERROR_UNKNOWN_HOST")]
        let reply = await call("network_requests", on: inspector)
        #expect(reply.text.contains("FAILED (NS_ERROR_UNKNOWN_HOST)"))
    }

    @Test("A screenshot comes back as an image, not as text")
    func screenshotIsImage() async {
        let inspector = FakeInspector()
        let reply = await call("page_screenshot", on: inspector)
        guard case .image(let data, let mimeType) = reply.content.first else {
            Issue.record("expected image content")
            return
        }
        #expect(data == inspector.screenshotData)
        #expect(mimeType == "image/png")
    }

    @Test("A browser error reaches the caller as a tool error")
    func browserErrorSurfaces() async {
        let inspector = FakeInspector()
        inspector.failure = .firefoxNotFound(path: "/fake/firefox")
        let reply = await call("open_url", ["url": .string("https://example.com/")], on: inspector)
        #expect(reply.isError)
        #expect(reply.text.contains("/fake/firefox"))
    }
}
