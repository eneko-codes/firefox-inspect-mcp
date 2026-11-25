import Foundation

/// Routes a `tools/call` to the inspector and renders the answer.
///
/// Never starts a browser itself — everything goes through `BrowserInspector`, which is
/// what lets the tests drive every branch below against a double with no Firefox.
public struct InspectTools: ToolHandler {
    private let inspector: any BrowserInspector
    private let timeout: Duration
    private let format = Format()

    public init(inspector: any BrowserInspector, timeout: Duration = ToolCatalog.deadline) {
        self.inspector = inspector
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<ToolOutput, any Error>.success(
                    ToolOutput(content: try await run(parameters), isError: false))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let output)?:
            return output
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                InspectError.timedOut(seconds: Int(timeout.components.seconds), tool: parameters.name),
                tool: parameters.name, since: started)
        }
    }

    private func failure(_ error: any Error, tool: String, since started: ContinuousClock.Instant)
        -> ToolOutput
    {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let message = (error as? InspectError)?.message ?? InspectError.browserLost.message
        return ToolOutput(text: message, isError: true)
    }

    private func text(_ text: String) -> [ToolOutput.Block] {
        [.text(text)]
    }

    private func run(_ parameters: ToolCall) async throws -> [ToolOutput.Block] {
        let arguments = Arguments(parameters.arguments)
        guard let allowed = ToolCatalog.argumentNames(of: parameters.name) else {
            throw InspectError.badArgument(
                name: "name",
                reason: "'\(ToolStandard.echo(parameters.name))' is not a tool of this server")
        }
        try arguments.refuseUnknown(allowed: allowed)

        switch parameters.name {
        case ToolCatalog.statusName:
            return text(format.status(await inspector.status()))

        case ToolCatalog.openURLName:
            return text(format.opened(try await inspector.open(url: try arguments.webURL("url"))))

        case ToolCatalog.elementsName:
            let selector = try arguments.optionalString("selector") ?? "html"
            let window = try arguments.window()
            let result = try await inspector.elements(selector: selector)
            return text(
                format.elements(
                    result, selector: selector, characterOffset: window.characterOffset,
                    maxCharacters: window.maxCharacters, notices: arguments.notices))

        case ToolCatalog.consoleName:
            let level = try arguments.optionalChoice("level", among: ToolCatalog.consoleLevels)
            let page = try arguments.page(
                defaultLimit: ToolCatalog.defaultConsoleLimit, limits: ToolCatalog.consoleLimitRange)
            let clear = try arguments.bool("clear")
            let history = try await inspector.consoleMessages(clear: clear)
            let matching = level.map { wanted in history.entries.filter { $0.level == wanted } } ?? history.entries
            return text(
                format.console(
                    matching, total: matching.count, dropped: history.dropped, limit: page.limit,
                    offset: page.offset, cleared: clear, notices: arguments.notices))

        case ToolCatalog.networkName:
            let filter = try arguments.optionalString("url_contains")
            let includeHeaders = try arguments.bool("include_headers")
            let page = try arguments.page(
                defaultLimit: ToolCatalog.defaultNetworkLimit, limits: ToolCatalog.networkLimitRange)
            let history = try await inspector.networkRequests()
            let matching = filter.map { text in history.entries.filter { $0.url.contains(text) } } ?? history.entries
            return text(
                format.network(
                    matching, total: matching.count, dropped: history.dropped, limit: page.limit,
                    offset: page.offset, includeHeaders: includeHeaders, notices: arguments.notices))

        case ToolCatalog.bodyName:
            let requestID = try arguments.requiredString("request_id")
            let window = try arguments.window()
            let body = try await inspector.responseBody(requestID: requestID)
            return text(
                format.body(
                    body, characterOffset: window.characterOffset,
                    maxCharacters: window.maxCharacters, notices: arguments.notices))

        case ToolCatalog.storageName:
            let page = try arguments.page(
                defaultLimit: ToolCatalog.defaultStorageLimit, limits: ToolCatalog.storageLimitRange)
            return text(
                format.storage(
                    try await inspector.storage(), limit: page.limit, offset: page.offset,
                    notices: arguments.notices))

        case ToolCatalog.screenshotName:
            let fitted = try ScreenshotFitter.fit(base64: try await inspector.screenshot())
            var blocks: [ToolOutput.Block] = []
            if let change = fitted.adjustment {
                blocks.append(
                    .text(
                        "The viewport was \(change.from.width)×\(change.from.height) pixels; the image is "
                            + "\(change.to.width)×\(change.to.height) \(fitted.mimeType == "image/png" ? "PNG" : "JPEG"), "
                            + "scaled to fit \(ToolCatalog.largestScreenshotSide) pixels and "
                            + "\(ToolCatalog.largestScreenshotBytes) bytes."))
            }
            blocks.append(.image(data: fitted.base64, mimeType: fitted.mimeType))
            return blocks

        default:
            throw InspectError.badArgument(
                name: "name",
                reason: "'\(ToolStandard.echo(parameters.name))' is not a tool of this server")
        }
    }
}
