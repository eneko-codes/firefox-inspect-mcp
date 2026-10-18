import Foundation
import MCP
import Testing

@testable import FirefoxInspectCore

/// Answers BiDi commands from a script and records what was asked. No socket, no browser.
actor ScriptedTransport: BiDiTransport {
    nonisolated let events: AsyncStream<BiDiEvent>
    private let sink: AsyncStream<BiDiEvent>.Continuation
    private(set) var methods: [String] = []
    var replies: [String: Value] = [
        "session.new": .object(["capabilities": .object(["browserVersion": .string("999.0")])]),
        "browsingContext.getTree": .object([
            "contexts": .array([.object(["context": .string("tab-1")])])
        ]),
        "script.callFunction": .object([
            "type": .string("success"),
            "result": .object([
                "type": .string("string"),
                "value": .string(#"{"url":"https://example.com/","title":"Fixture page"}"#),
            ]),
        ]),
    ]

    init() {
        (events, sink) = AsyncStream.makeStream(of: BiDiEvent.self)
    }

    func send(_ method: String, _ params: Value) async throws -> Value {
        methods.append(method)
        return replies[method] ?? .object([:])
    }

    func emit(_ event: BiDiEvent) { sink.yield(event) }
    func close() { sink.finish() }
}

final class ShutdownCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

@Suite("Firefox inspector")
struct FirefoxInspectorTests {

    private func makeInspector(_ transport: ScriptedTransport, _ counter: ShutdownCounter)
        -> FirefoxInspector
    {
        FirefoxInspector(executable: "/fake/firefox") { _ in
            BrowserConnection(transport: transport, shutDown: { counter.increment() })
        }
    }

    @Test("The first call starts the session, subscribes to events and finds the tab")
    func startup() async throws {
        let transport = ScriptedTransport()
        let inspector = makeInspector(transport, ShutdownCounter())

        let page = try await inspector.open(url: "https://example.com/")

        #expect(page == PageInfo(url: "https://example.com/", title: "Fixture page"))
        let methods = await transport.methods
        #expect(methods.prefix(4) == ["session.new", "session.subscribe", "network.addDataCollector", "browsingContext.getTree"])
        #expect(methods.contains("browsingContext.navigate"))
        #expect(await inspector.status().version == "999.0")
    }

    @Test("Two calls arriving together start one browser, not two")
    func singleStart() async throws {
        let transport = ScriptedTransport()
        let inspector = makeInspector(transport, ShutdownCounter())

        async let first = inspector.networkRequests()
        async let second = inspector.consoleMessages(clear: false)
        _ = try await (first, second)

        #expect(await transport.methods.filter { $0 == "session.new" }.count == 1)
    }

    @Test("Opening a page forgets the previous page's console history")
    func openClearsHistory() async throws {
        let transport = ScriptedTransport()
        let inspector = makeInspector(transport, ShutdownCounter())
        _ = try await inspector.consoleMessages(clear: false)

        await transport.emit(BiDiEvent(method: "log.entryAdded", params: .object([
            "type": .string("console"), "level": .string("info"), "text": .string("old"),
            "timestamp": .int(1), "source": .object(["context": .string("tab-1")]),
        ])))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await inspector.consoleMessages(clear: false).map(\.text) == ["old"])

        _ = try await inspector.open(url: "https://example.com/next")
        #expect(try await inspector.consoleMessages(clear: false).isEmpty)
    }

    @Test("shutdown ends the session and stops the browser exactly once")
    func shutdownOnce() async throws {
        let transport = ScriptedTransport()
        let counter = ShutdownCounter()
        let inspector = makeInspector(transport, counter)
        _ = try await inspector.networkRequests()

        await inspector.shutdown()
        await inspector.shutdown()

        #expect(counter.count == 1)
        #expect(await transport.methods.contains("session.end"))
        #expect(await inspector.status().isRunning == false)
    }
}
