import Foundation

/// Turns BiDi events into the console and network history the tools report.
///
/// A value type with no I/O so the tests can feed it recorded event shapes. Both lists
/// are capped: a page that logs in a loop must not grow the server without bound, and the
/// oldest entries are the ones dropped.
struct EventBuffer {
    static let consoleCapacity = 500
    static let networkCapacity = 1_000

    private(set) var console: [ConsoleEntry] = []
    private var requests: [String: NetworkEntry] = [:]
    private var order: [String] = []
    private var startTimestamps: [String: Double] = [:]

    /// In the order the requests were first seen.
    var network: [NetworkEntry] { order.compactMap { requests[$0] } }

    mutating func clear() {
        console = []
        requests = [:]
        order = []
        startTimestamps = [:]
    }

    mutating func clearConsole() {
        console = []
    }

    /// `context` limits recording to the one tab this server drives.
    mutating func apply(_ event: BiDiEvent, context: String?) {
        guard let object = event.params.objectValue else { return }
        switch event.method {
        case "log.entryAdded":
            let source = object["source"]?.objectValue?["context"]?.stringValue
            guard context == nil || source == context else { return }
            appendConsole(object)

        case "network.beforeRequestSent":
            guard context == nil || object["context"]?.stringValue == context else { return }
            startRequest(object)

        case "network.responseCompleted":
            guard context == nil || object["context"]?.stringValue == context else { return }
            completeRequest(object)

        case "network.fetchError":
            guard context == nil || object["context"]?.stringValue == context else { return }
            failRequest(object)

        default:
            break
        }
    }

    // MARK: Console

    private mutating func appendConsole(_ object: [String: Value]) {
        let entry = ConsoleEntry(
            level: object["level"]?.stringValue ?? "info",
            source: object["type"]?.stringValue ?? "console",
            text: object["text"]?.stringValue ?? "",
            timestamp: Self.date(object["timestamp"])
        )
        console.append(entry)
        if console.count > Self.consoleCapacity {
            console.removeFirst(console.count - Self.consoleCapacity)
        }
    }

    // MARK: Network

    private mutating func startRequest(_ object: [String: Value]) {
        guard let request = object["request"]?.objectValue,
            let identifier = request["request"]?.stringValue
        else { return }

        let entry = NetworkEntry(
            id: identifier,
            method: request["method"]?.stringValue ?? "GET",
            url: request["url"]?.stringValue ?? "",
            requestHeaders: Self.headers(request["headers"])
        )
        if requests[identifier] == nil {
            order.append(identifier)
            if order.count > Self.networkCapacity {
                let dropped = order.removeFirst()
                requests[dropped] = nil
                startTimestamps[dropped] = nil
            }
        }
        // A redirect reuses the id; the entry then describes the hop still in flight.
        requests[identifier] = entry
        if let timestamp = object["timestamp"]?.doubleValue ?? object["timestamp"]?.intValue.map(Double.init) {
            startTimestamps[identifier] = timestamp
        }
    }

    private mutating func completeRequest(_ object: [String: Value]) {
        guard let request = object["request"]?.objectValue,
            let identifier = request["request"]?.stringValue,
            var entry = requests[identifier]
        else { return }

        let response = object["response"]?.objectValue ?? [:]
        entry.status = response["status"]?.intValue
        entry.mimeType = response["mimeType"]?.stringValue
        entry.bytes = response["bytesReceived"]?.intValue
        entry.responseHeaders = Self.headers(response["headers"])
        if let end = object["timestamp"]?.doubleValue ?? object["timestamp"]?.intValue.map(Double.init),
            let start = startTimestamps[identifier]
        {
            entry.durationMilliseconds = max(0, Int(end - start))
        }
        requests[identifier] = entry
    }

    private mutating func failRequest(_ object: [String: Value]) {
        guard let request = object["request"]?.objectValue,
            let identifier = request["request"]?.stringValue,
            var entry = requests[identifier]
        else { return }
        entry.failure = object["errorText"]?.stringValue ?? "failed"
        requests[identifier] = entry
    }

    // MARK: Decoding

    /// BiDi headers are `{name, value: {type: "string" | "base64", value}}`. Base64
    /// values are not decoded: they are bytes, not text, and are shown as received.
    static func headers(_ value: Value?) -> [HTTPHeader] {
        guard let list = value?.arrayValue else { return [] }
        return list.compactMap { item in
            guard let object = item.objectValue, let name = object["name"]?.stringValue else {
                return nil
            }
            return HTTPHeader(name: name, value: object["value"]?.objectValue?["value"]?.stringValue ?? "")
        }
    }

    static func date(_ value: Value?) -> Date {
        let milliseconds = value?.doubleValue ?? value?.intValue.map(Double.init) ?? 0
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}
