import Foundation

/// Routes a `tools/call` to the inspector and renders the answer.
///
/// Never starts a browser itself — everything goes through `BrowserInspector`, which is
/// what lets the tests drive every branch below against a double with no Firefox.
public struct InspectTools: ToolHandler {
    private let inspector: any BrowserInspector
    private let format = Format()

    public init(inspector: any BrowserInspector) {
        self.inspector = inspector
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        do {
            return ToolOutput(content: try await run(parameters), isError: false)
        } catch let error as InspectError {
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(text: error.message, isError: true)
        } catch {
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(text: InspectError.browserLost.message, isError: true)
        }
    }

    private func text(_ text: String) -> [ToolOutput.Block] {
        [.text(text)]
    }

    private func run(_ parameters: ToolCall) async throws -> [ToolOutput.Block] {
        let arguments = Arguments(parameters.arguments)

        switch parameters.name {
        case ToolCatalog.statusName:
            return text(format.status(await inspector.status()))

        case ToolCatalog.openURLName:
            return text(format.opened(try await inspector.open(url: try arguments.webURL("url"))))

        case ToolCatalog.elementsName:
            let selector = arguments.optionalString("selector") ?? "html"
            let limit = try arguments.int(
                "max_characters", default: 10_000, in: 100...Configuration.characterLimit)
            let result = try await inspector.elements(selector: selector, characterLimit: limit)
            return text(format.elements(result, selector: selector))

        case ToolCatalog.consoleName:
            let level = arguments.optionalString("level")?.lowercased()
            let limit = try arguments.int(
                "limit", default: Configuration.defaultListLimit, in: Configuration.listLimitRange)
            let all = try await inspector.consoleMessages(clear: arguments.bool("clear"))
            let matching = level.map { wanted in all.filter { $0.level == wanted } } ?? all
            return text(format.console(Array(matching.suffix(limit)), total: matching.count))

        case ToolCatalog.networkName:
            let filter = arguments.optionalString("url_contains")
            let limit = try arguments.int(
                "limit", default: Configuration.defaultListLimit, in: Configuration.listLimitRange)
            let all = try await inspector.networkRequests()
            let matching = filter.map { text in all.filter { $0.url.contains(text) } } ?? all
            return text(
                format.network(
                    Array(matching.prefix(limit)), total: matching.count,
                    includeHeaders: arguments.bool("include_headers")))

        case ToolCatalog.bodyName:
            let limit = try arguments.int(
                "max_characters", default: 10_000, in: 100...Configuration.characterLimit)
            let body = try await inspector.responseBody(
                requestID: try arguments.requiredString("request_id"), characterLimit: limit)
            return text(format.body(body))

        case ToolCatalog.storageName:
            return text(format.storage(try await inspector.storage()))

        case ToolCatalog.screenshotName:
            let png = try await inspector.screenshot()
            return [.image(data: png, mimeType: "image/png")]

        default:
            throw InspectError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }
}
