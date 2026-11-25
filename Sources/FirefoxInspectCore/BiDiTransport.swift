import Foundation

/// One event pushed by Firefox, e.g. `log.entryAdded`.
public struct BiDiEvent: Sendable {
    public let method: String
    public let params: Value
}

/// A command Firefox answered with an error. Only the error code is kept: the message
/// and stack trace quote page URLs and selectors, and must not reach a log.
public struct BiDiError: Error, Equatable {
    public let code: String
    let message: String

    public init(code: String, message: String = "") {
        self.code = code
        self.message = message
    }

    /// Firefox's own error token (`NS_ERROR_UNKNOWN_HOST`) when the message carries one.
    /// A fixed vocabulary, unlike the rest of the message, which quotes the URL.
    var firefoxErrorToken: String? {
        guard let range = message.range(of: "NS_[A-Z_]+", options: .regularExpression) else {
            return nil
        }
        return String(message[range])
    }
}

/// The WebDriver BiDi wire, abstracted so the inspector can be driven by a double.
public protocol BiDiTransport: Sendable {
    /// Sends a command and returns its `result`. Throws `BiDiError` on a protocol error.
    func send(_ method: String, _ params: Value) async throws -> Value
    var events: AsyncStream<BiDiEvent> { get }
    func close() async
}

enum TransportError: Error {
    case timedOut
    case closed
    case malformed
}

/// BiDi over a single WebSocket, using Foundation's `URLSessionWebSocketTask`.
actor WebSocketTransport: BiDiTransport {
    nonisolated let events: AsyncStream<BiDiEvent>
    private let eventSink: AsyncStream<BiDiEvent>.Continuation

    private let socket: URLSessionWebSocketTask
    private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
    private var nextIdentifier = 1
    private var receiveLoop: Task<Void, Never>?
    private var isClosed = false

    /// Commands that outlive this are abandoned: a hung page must not hang the server.
    static let commandTimeout: Duration = .seconds(30)

    init(url: URL) {
        (events, eventSink) = AsyncStream.makeStream(of: BiDiEvent.self, bufferingPolicy: .unbounded)
        socket = URLSession.shared.webSocketTask(with: url)
    }

    func start() {
        socket.resume()
        receiveLoop = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    let message = try await self.socket.receive()
                    await self.handle(message)
                } catch {
                    await self.fail()
                    return
                }
            }
        }
    }

    func send(_ method: String, _ params: Value) async throws -> Value {
        guard !isClosed else { throw TransportError.closed }
        let identifier = nextIdentifier
        nextIdentifier += 1
        let command = Value.object([
            "id": .int(identifier), "method": .string(method), "params": params,
        ])
        let text = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)

        let deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.commandTimeout)
            guard !Task.isCancelled else { return }
            await self?.resume(identifier, throwing: TransportError.timedOut)
        }
        defer { deadline.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pending[identifier] = continuation
            Task {
                do { try await socket.send(.string(text)) } catch {
                    self.resume(identifier, throwing: error)
                }
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        receiveLoop?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        failPending(TransportError.closed)
        eventSink.finish()
    }

    // MARK: Internals

    private func resume(_ identifier: Int, throwing error: Error) {
        pending.removeValue(forKey: identifier)?.resume(throwing: error)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }
        guard let frame = try? JSONDecoder().decode(Value.self, from: data),
            let object = frame.objectValue
        else { return }

        if let identifier = object["id"]?.intValue {
            guard let continuation = pending.removeValue(forKey: identifier) else { return }
            if object["type"]?.stringValue == "error" {
                continuation.resume(
                    throwing: BiDiError(
                        code: object["error"]?.stringValue ?? "unknown",
                        message: object["message"]?.stringValue ?? ""))
            } else {
                continuation.resume(returning: object["result"] ?? .null)
            }
        } else if object["type"]?.stringValue == "event", let method = object["method"]?.stringValue {
            eventSink.yield(BiDiEvent(method: method, params: object["params"] ?? .null))
        }
    }

    private func fail() {
        guard !isClosed else { return }
        isClosed = true
        failPending(TransportError.closed)
        eventSink.finish()
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
