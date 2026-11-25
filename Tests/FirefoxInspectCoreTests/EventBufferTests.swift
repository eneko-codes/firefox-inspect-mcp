import Foundation
import Testing

@testable import FirefoxInspectCore

@Suite("Event buffer")
struct EventBufferTests {

    private func header(_ name: String, _ value: String) -> Value {
        .object(["name": .string(name), "value": .object(["type": .string("string"), "value": .string(value)])])
    }

    private func request(_ id: String, url: String = "https://example.com/a.js") -> Value {
        .object([
            "request": .string(id), "url": .string(url), "method": .string("GET"),
            "headers": .array([header("Accept", "*/*")]),
        ])
    }

    private func started(_ id: String, context: String = "tab", at time: Int = 1_000) -> BiDiEvent {
        BiDiEvent(method: "network.beforeRequestSent", params: .object([
            "context": .string(context), "request": request(id), "timestamp": .int(time),
        ]))
    }

    private func completed(_ id: String, status: Int, at time: Int) -> BiDiEvent {
        BiDiEvent(method: "network.responseCompleted", params: .object([
            "context": .string("tab"), "request": request(id), "timestamp": .int(time),
            "response": .object([
                "status": .int(status), "mimeType": .string("text/javascript"),
                "bytesReceived": .int(512), "headers": .array([header("Content-Type", "text/javascript")]),
            ]),
        ]))
    }

    @Test("A request is paired with its response and timed")
    func pairsRequestAndResponse() {
        var buffer = EventBuffer()
        buffer.apply(started("1", at: 1_000), context: "tab")
        buffer.apply(completed("1", status: 200, at: 1_150), context: "tab")

        let entry = buffer.network.first
        #expect(buffer.network.count == 1)
        #expect(entry?.status == 200)
        #expect(entry?.durationMilliseconds == 150)
        #expect(entry?.bytes == 512)
        #expect(entry?.requestHeaders == [HTTPHeader(name: "Accept", value: "*/*")])
        #expect(entry?.responseHeaders == [HTTPHeader(name: "Content-Type", value: "text/javascript")])
    }

    @Test("Traffic from another browsing context is ignored")
    func otherContextIgnored() {
        var buffer = EventBuffer()
        buffer.apply(started("1", context: "popup"), context: "tab")
        #expect(buffer.network.isEmpty)
    }

    @Test("A request that never completed keeps its failure text")
    func failure() {
        var buffer = EventBuffer()
        buffer.apply(started("1"), context: "tab")
        buffer.apply(BiDiEvent(method: "network.fetchError", params: .object([
            "context": .string("tab"), "request": request("1"), "errorText": .string("NS_ERROR_NET_RESET"),
        ])), context: "tab")
        #expect(buffer.network.first?.failure == "NS_ERROR_NET_RESET")
    }

    @Test("Console and uncaught errors are recorded with their origin")
    func console() {
        var buffer = EventBuffer()
        let source = Value.object(["context": .string("tab")])
        buffer.apply(BiDiEvent(method: "log.entryAdded", params: .object([
            "type": .string("console"), "level": .string("warn"), "text": .string("careful"),
            "timestamp": .int(5_000), "source": source,
        ])), context: "tab")
        buffer.apply(BiDiEvent(method: "log.entryAdded", params: .object([
            "type": .string("javascript"), "level": .string("error"), "text": .string("boom"),
            "timestamp": .int(6_000), "source": source,
        ])), context: "tab")
        #expect(buffer.console.map(\.text) == ["careful", "boom"])
        #expect(buffer.console.map(\.source) == ["console", "javascript"])
    }

    @Test("The history is capped and drops the oldest entries")
    func capped() {
        var buffer = EventBuffer()
        let source = Value.object(["context": .string("tab")])
        for index in 0..<(EventBuffer.consoleCapacity + 10) {
            buffer.apply(BiDiEvent(method: "log.entryAdded", params: .object([
                "type": .string("console"), "level": .string("info"), "text": .string("m\(index)"),
                "timestamp": .int(index), "source": source,
            ])), context: "tab")
        }
        #expect(buffer.console.count == EventBuffer.consoleCapacity)
        #expect(buffer.console.first?.text == "m10")
    }

    @Test("Entries dropped from a full history are counted, and clearing resets the count")
    func droppedAreCounted() {
        var buffer = EventBuffer()
        let source = Value.object(["context": .string("tab")])
        for index in 0..<(EventBuffer.consoleCapacity + 4) {
            buffer.apply(BiDiEvent(method: "log.entryAdded", params: .object([
                "type": .string("console"), "level": .string("info"), "text": .string("m\(index)"),
                "timestamp": .int(index), "source": source,
            ])), context: "tab")
        }
        for index in 0..<(EventBuffer.networkCapacity + 6) {
            buffer.apply(started("r\(index)"), context: "tab")
        }
        #expect(buffer.droppedConsole == 4)
        #expect(buffer.droppedNetwork == 6)
        #expect(buffer.network.count == EventBuffer.networkCapacity)

        buffer.clearConsole()
        #expect(buffer.droppedConsole == 0 && buffer.droppedNetwork == 6)
        buffer.clear()
        #expect(buffer.droppedNetwork == 0)
    }

    @Test("clear empties both histories")
    func clearing() {
        var buffer = EventBuffer()
        buffer.apply(started("1"), context: "tab")
        buffer.clear()
        #expect(buffer.network.isEmpty)
        #expect(buffer.console.isEmpty)
    }
}
