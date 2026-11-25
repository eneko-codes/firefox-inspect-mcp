import Foundation

/// A connected browser: the BiDi wire plus how to shut the process behind it down.
struct BrowserConnection: Sendable {
    var transport: any BiDiTransport
    var shutDown: @Sendable () -> Void
}

/// Drives one Firefox over WebDriver BiDi. Starts it on first use, from a throwaway
/// profile, and owns its whole lifetime.
public actor FirefoxInspector: BrowserInspector {
    private let executable: String
    private let connect: @Sendable (String) async throws -> BrowserConnection

    private var connection: BrowserConnection?
    private var startup: Task<BrowserConnection, Error>?
    private var context: String?
    private var version: String?
    private var buffer = EventBuffer()

    public init(executable: String) {
        self.executable = executable
        self.connect = Self.launchFirefox
    }

    /// For the tests: supplies the connection instead of starting Firefox.
    init(
        executable: String,
        connect: @escaping @Sendable (String) async throws -> BrowserConnection
    ) {
        self.executable = executable
        self.connect = connect
    }

    private static let launchFirefox: @Sendable (String) async throws -> BrowserConnection = {
        executable in
        let (process, endpoint) = try await FirefoxProcess.launch(executable: executable)
        let transport = WebSocketTransport(url: endpoint.appendingPathComponent("session"))
        await transport.start()
        return BrowserConnection(transport: transport, shutDown: { process.stop() })
    }

    // MARK: Lifecycle

    public func status() -> BrowserStatus {
        BrowserStatus(
            executablePath: executable,
            executableExists: FileManager.default.isExecutableFile(atPath: executable),
            isRunning: connection != nil, version: version)
    }

    /// Ends the session and removes the profile. Safe to call more than once.
    public func shutdown() async {
        startup?.cancel()
        startup = nil
        guard let connection else { return }
        self.connection = nil
        _ = try? await connection.transport.send("session.end", .object([:]))
        await connection.transport.close()
        connection.shutDown()
    }

    /// One start at a time: two tool calls arriving together must not launch two browsers.
    private func ready() async throws -> BrowserConnection {
        if let connection { return connection }
        if let startup { return try await startup.value }

        let task = Task { try await self.begin() }
        startup = task
        defer { startup = nil }
        return try await task.value
    }

    private func begin() async throws -> BrowserConnection {
        let launchStart = ContinuousClock.now
        let started = try await connect(executable)
        do {
            let created = try await started.transport.send(
                "session.new", .object(["capabilities": .object([:])]))
            version = created.objectValue?["capabilities"]?.objectValue?["browserVersion"]?.stringValue

            _ = try await started.transport.send(
                "session.subscribe",
                .object([
                    "events": .array([
                        .string("log.entryAdded"), .string("network.beforeRequestSent"),
                        .string("network.responseCompleted"), .string("network.fetchError"),
                    ])
                ]))

            // Without a collector Firefox discards response bodies. A failure here only
            // costs network_response_body, so it does not stop the browser from starting.
            _ = try? await started.transport.send(
                "network.addDataCollector",
                .object([
                    "dataTypes": .array([.string("response")]),
                    "maxEncodedDataSize": .int(5_000_000),
                ]))

            let tree = try await started.transport.send("browsingContext.getTree", .object([:]))
            guard
                let first = tree.objectValue?["contexts"]?.arrayValue?.first?.objectValue?["context"]?
                    .stringValue
            else { throw InspectError.browserLost }
            context = first
        } catch {
            await started.transport.close()
            started.shutDown()
            throw Self.translate(error)
        }

        Diagnostics.browserStarted(since: launchStart)
        connection = started
        buffer = EventBuffer()
        let events = started.transport.events
        Task { [weak self] in
            for await event in events { await self?.record(event) }
            await self?.connectionEnded()
        }
        return started
    }

    private func record(_ event: BiDiEvent) {
        buffer.apply(event, context: context)
    }

    /// The event stream finishes when the socket drops, i.e. Firefox died or was closed.
    private func connectionEnded() {
        guard let lost = connection else { return }
        connection = nil
        context = nil
        lost.shutDown()
    }

    private static func translate(_ error: Error) -> Error {
        switch error {
        case let error as InspectError: return error
        case let error as BiDiError: return InspectError.commandFailed(code: error.code)
        case TransportError.timedOut: return InspectError.commandFailed(code: "timeout")
        default: return InspectError.browserLost
        }
    }

    // MARK: BrowserInspector

    public func open(url: String) async throws -> PageInfo {
        let connection = try await ready()
        let context = try currentContext()
        buffer.clear()
        do {
            _ = try await connection.transport.send(
                "browsingContext.navigate",
                .object([
                    "context": .string(context), "url": .string(url), "wait": .string("complete"),
                ]))
        } catch let error as BiDiError {
            throw InspectError.navigationFailed(code: error.firefoxErrorToken ?? error.code)
        } catch {
            throw Self.translate(error)
        }
        return try await pageInfo()
    }

    public func elements(selector: String, characterLimit: Int) async throws -> ElementsResult {
        let reply = try await script(
            """
            (selector, limit) => {
              let nodes;
              try { nodes = document.querySelectorAll(selector); }
              catch (error) { return JSON.stringify({invalid: true}); }
              const html = nodes.length ? nodes[0].outerHTML : "";
              return JSON.stringify({
                count: nodes.length, html: html.slice(0, limit), truncated: html.length > limit
              });
            }
            """, arguments: [.string(selector), .int(characterLimit)])

        guard reply.objectValue?["invalid"]?.boolValue != true else {
            throw InspectError.badArgument(name: "selector", reason: "it is not a valid CSS selector")
        }
        return ElementsResult(
            matchCount: reply.objectValue?["count"]?.intValue ?? 0,
            html: reply.objectValue?["html"]?.stringValue ?? "",
            isTruncated: reply.objectValue?["truncated"]?.boolValue ?? false)
    }

    public func consoleMessages(clear: Bool) async throws -> [ConsoleEntry] {
        _ = try await ready()
        let entries = buffer.console
        if clear { buffer.clearConsole() }
        return entries
    }

    public func networkRequests() async throws -> [NetworkEntry] {
        _ = try await ready()
        return buffer.network
    }

    public func responseBody(requestID: String, characterLimit: Int) async throws -> ResponseBody {
        let connection = try await ready()
        guard buffer.network.contains(where: { $0.id == requestID }) else {
            throw InspectError.requestNotFound(id: requestID)
        }
        let reply: Value
        do {
            reply = try await connection.transport.send(
                "network.getData",
                .object(["request": .string(requestID), "dataType": .string("response")]))
        } catch let error as BiDiError {
            if error.code == "no such network data" { throw InspectError.bodyUnavailable(id: requestID) }
            throw InspectError.commandFailed(code: error.code)
        } catch {
            throw Self.translate(error)
        }

        let bytes = reply.objectValue?["bytes"]?.objectValue
        let isBase64 = bytes?["type"]?.stringValue == "base64"
        let text = bytes?["value"]?.stringValue ?? ""
        return ResponseBody(
            text: String(text.prefix(characterLimit)), isBase64: isBase64,
            isTruncated: text.count > characterLimit)
    }

    public func storage() async throws -> StorageSnapshot {
        let connection = try await ready()
        let local = try await script(
            """
            () => {
              const dump = (store) => {
                const out = {};
                try { for (let i = 0; i < store.length; i++) { out[store.key(i)] = store.getItem(store.key(i)); } }
                catch (error) {}
                return out;
              };
              return JSON.stringify({local: dump(localStorage), session: dump(sessionStorage)});
            }
            """)

        // Through BiDi rather than document.cookie, so HttpOnly cookies are included.
        let cookies: Value
        do {
            cookies = try await connection.transport.send("storage.getCookies", .object([:]))
        } catch {
            throw Self.translate(error)
        }

        return StorageSnapshot(
            cookies: (cookies.objectValue?["cookies"]?.arrayValue ?? []).compactMap { item in
                guard let cookie = item.objectValue, let name = cookie["name"]?.stringValue else {
                    return nil
                }
                return CookieInfo(
                    name: name, domain: cookie["domain"]?.stringValue ?? "",
                    path: cookie["path"]?.stringValue ?? "/",
                    value: cookie["value"]?.objectValue?["value"]?.stringValue ?? "",
                    isHTTPOnly: cookie["httpOnly"]?.boolValue ?? false,
                    isSecure: cookie["secure"]?.boolValue ?? false)
            },
            local: Self.strings(local.objectValue?["local"]),
            session: Self.strings(local.objectValue?["session"]))
    }

    public func screenshot() async throws -> String {
        let connection = try await ready()
        let context = try currentContext()
        do {
            let reply = try await connection.transport.send(
                "browsingContext.captureScreenshot",
                .object(["context": .string(context)]))
            guard let data = reply.objectValue?["data"]?.stringValue else {
                throw InspectError.commandFailed(code: "no screenshot data")
            }
            return data
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: Helpers

    private func currentContext() throws -> String {
        guard let context else { throw InspectError.browserLost }
        return context
    }

    private func pageInfo() async throws -> PageInfo {
        let reply = try await script("() => JSON.stringify({url: location.href, title: document.title})")
        return PageInfo(
            url: reply.objectValue?["url"]?.stringValue ?? "",
            title: reply.objectValue?["title"]?.stringValue ?? "")
    }

    /// Calls a function in the page and parses the JSON string it returns. Functions go
    /// through `arguments` rather than string interpolation, so a selector can never
    /// become code.
    private func script(_ declaration: String, arguments: [Value] = []) async throws -> Value {
        let connection = try await ready()
        let context = try currentContext()

        let reply: Value
        do {
            reply = try await connection.transport.send(
                "script.callFunction",
                .object([
                    "functionDeclaration": .string(declaration),
                    "awaitPromise": .bool(false),
                    "target": .object(["context": .string(context)]),
                    "arguments": .array(arguments.map(Self.remoteValue)),
                    "resultOwnership": .string("none"),
                ]))
        } catch {
            throw Self.translate(error)
        }

        let object = reply.objectValue
        if object?["type"]?.stringValue == "exception" {
            let detail = object?["exceptionDetails"]?.objectValue?["text"]?.stringValue ?? "exception"
            throw InspectError.pageScriptFailed(detail)
        }
        guard let json = object?["result"]?.objectValue?["value"]?.stringValue,
            let parsed = try? JSONDecoder().decode(Value.self, from: Data(json.utf8))
        else { throw InspectError.pageScriptFailed("the page returned no data") }
        return parsed
    }

    private static func remoteValue(_ value: Value) -> Value {
        switch value {
        case .string: return .object(["type": .string("string"), "value": value])
        case .int: return .object(["type": .string("number"), "value": value])
        default: return .object(["type": .string("undefined")])
        }
    }

    private static func strings(_ value: Value?) -> [String: String] {
        (value?.objectValue ?? [:]).compactMapValues { $0.stringValue }
    }
}
