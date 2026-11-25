import Foundation
import ImageIO
import Testing

@testable import FirefoxInspectCore

/// The edges of the tool standard for this server's tools: each bound and one past it, the
/// text of each notice, pages and windows that chain, the longest result, and the texts the
/// model reads. Every page, request, cookie and message in here is invented.
@Suite("Bounds")
struct BoundsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:], on inspector: FakeInspector
    ) async -> ToolOutput {
        await InspectTools(inspector: inspector).handle(.init(name: name, arguments: arguments))
    }

    private static func padded(_ index: Int) -> String { String(format: "%04d", index) }

    /// Text of exactly `width` characters that starts with `lead`, so that looking for a row
    /// never has to walk the filler.
    private static func filled(_ lead: String, to width: Int) -> String {
        lead + String(repeating: "x", count: max(width - lead.count, 0))
    }

    // MARK: One table of listings

    /// One listing tool, and an inspector holding `count` rows of the widest width a row
    /// gets before it is clipped. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var arguments: [String: Value] = [:]
        var inspector: @Sendable (Int) -> FakeInspector
        var row: @Sendable (Int) -> String

        var testDescription: String { tool }

        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }
    }

    private static let console = Listing(
        tool: ToolCatalog.consoleName, things: "console messages",
        limits: ToolCatalog.consoleLimitRange, defaultLimit: ToolCatalog.defaultConsoleLimit,
        inspector: { count in
            let inspector = FakeInspector()
            inspector.console = (0..<count).map {
                ConsoleEntry(
                    level: "warn", source: "javascript",
                    text: filled("row-\(padded($0))-", to: ToolCatalog.consoleTextWidth),
                    timestamp: Date(timeIntervalSince1970: 0))
            }
            return inspector
        },
        row: { "row-\(padded($0))-" })

    private static let network = Listing(
        tool: ToolCatalog.networkName, things: "requests", limits: ToolCatalog.networkLimitRange,
        defaultLimit: ToolCatalog.defaultNetworkLimit,
        inspector: { count in
            let inspector = FakeInspector()
            inspector.network = (0..<count).map {
                NetworkEntry(
                    id: filled("id-\(padded($0))-", to: ToolCatalog.nameWidth), method: "OPTIONS",
                    url: filled("https://example.com/row-\(padded($0))-", to: ToolCatalog.urlWidth),
                    status: 200, mimeType: filled("application/", to: ToolCatalog.nameWidth),
                    bytes: 123_456_789, durationMilliseconds: 123_456)
            }
            return inspector
        },
        row: { "row-\(padded($0))-" })

    private static let storage = Listing(
        tool: ToolCatalog.storageName, things: "storage entries",
        limits: ToolCatalog.storageLimitRange, defaultLimit: ToolCatalog.defaultStorageLimit,
        inspector: { count in
            let inspector = FakeInspector()
            // Local entries and cookies, so that a page can end in the other kind.
            let cookies = count / 2
            inspector.snapshot = StorageSnapshot(
                cookies: (0..<cookies).map {
                    CookieInfo(
                        name: filled("row-\(padded($0))-", to: ToolCatalog.nameWidth),
                        domain: filled("a.example.com", to: ToolCatalog.nameWidth),
                        path: filled("/", to: ToolCatalog.nameWidth),
                        value: filled("v", to: ToolCatalog.storageValueWidth), isHTTPOnly: true,
                        isSecure: true)
                },
                local: Dictionary(
                    uniqueKeysWithValues: (cookies..<count).map {
                        (
                            filled("row-\(padded($0))-", to: ToolCatalog.nameWidth),
                            filled("v", to: ToolCatalog.storageValueWidth)
                        )
                    }),
                session: [:])
            return inspector
        },
        row: { "row-\(padded($0))-" })

    private static let listings = [console, network, storage]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await call(listing.tool, listing.arguments, on: listing.inspector(total))
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await call(listing.tool, listing.arguments, on: listing.inspector(listing.defaultLimit))
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await call(listing.tool, ["limit": .int(maximum)], on: listing.inspector(total))
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await call(listing.tool, ["limit": .int(maximum + 1)], on: listing.inspector(total))
        #expect(
            over.text.hasPrefix(
                "limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nShowing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n\n"))

        let under = await call(listing.tool, ["limit": .int(0)], on: listing.inspector(total))
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let inspector = listing.inspector(7)
        let first = await call(listing.tool, ["limit": .int(3)], on: inspector)
        #expect(first.text.hasPrefix("Showing 1–3 of 7 \(listing.things). Pass offset=3 for the next page.\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await call(listing.tool, ["limit": .int(3), "offset": .int(3)], on: inspector)
        #expect(second.text.hasPrefix("Showing 4–6 of 7 \(listing.things). Pass offset=6 for the next page.\n\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await call(listing.tool, ["limit": .int(3), "offset": .int(6)], on: inspector)
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let inspector = listing.inspector(7)
        let past = await call(listing.tool, ["offset": .int(7)], on: inspector)
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all."))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)

        let negative = await call(listing.tool, ["offset": .int(-1)], on: inspector)
        let range = ToolCatalog.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("An empty history says so, with no page notice")
    func emptyHistories() async {
        for listing in [Self.console, Self.network] {
            let result = await call(listing.tool, [:], on: listing.inspector(0))
            #expect(!result.text.contains("Showing"), "\(listing.tool)")
        }
        #expect(await call("console_messages", on: FakeInspector()).text == "No console messages.")
        #expect(await call("network_requests", on: FakeInspector()).text == "No requests.")
    }

    // MARK: Order and what was dropped

    @Test("The three kinds of storage are listed in one stated order, a page may end in another kind")
    func storageOrder() async {
        let inspector = FakeInspector()
        func cookie(_ name: String, _ domain: String) -> CookieInfo {
            CookieInfo(name: name, domain: domain, path: "/", value: "v", isHTTPOnly: false, isSecure: false)
        }
        inspector.snapshot = StorageSnapshot(
            cookies: [cookie("b", "b.example.com"), cookie("z", "a.example.com"), cookie("a", "a.example.com")],
            local: ["m": "1", "k": "2"], session: ["s": "3"])
        let result = await call("page_storage", ["limit": .int(4), "offset": .int(1)], on: inspector)
        #expect(result.text.hasPrefix("Showing 2–5 of 6 storage entries. Pass offset=5 for the next page.\n\n"))
        let body = result.text.components(separatedBy: "\n\n").last ?? ""
        #expect(
            body == "Cookies (3):\n  z=v  [a.example.com/]\n  b=v  [b.example.com/]\nlocalStorage (2):\n  k=2\n  m=1")
    }

    @Test("A history that dropped its oldest entries says how many, before the data")
    func droppedEntries() async {
        let console = FakeInspector()
        console.console = Self.console.inspector(2).console
        console.droppedConsole = 7
        let consoleResult = await call("console_messages", on: console)
        #expect(
            consoleResult.text.hasPrefix(
                "The oldest 7 console messages were dropped because the history of \(EventBuffer.consoleCapacity) was full; the rows below start after them.\n\n"))

        let network = Self.network.inspector(2)
        network.droppedNetwork = 3
        let networkResult = await call("network_requests", on: network)
        #expect(
            networkResult.text.hasPrefix(
                "The oldest 3 requests were dropped because the history of \(EventBuffer.networkCapacity) was full; the rows below start after them.\n\n"))
        #expect(!(await call("console_messages", on: Self.console.inspector(2))).text.contains("dropped"))
    }

    // MARK: Clipping

    @Test("A field is clipped only past its width, and a clipped one says the rest cannot be read again")
    func clipping() async {
        let inspector = FakeInspector()
        let width = ToolCatalog.consoleTextWidth
        func entry(_ text: String) -> ConsoleEntry {
            ConsoleEntry(level: "info", source: "console", text: text, timestamp: Date(timeIntervalSince1970: 0))
        }
        inspector.console = [entry(String(repeating: "a", count: width))]
        #expect(!(await call("console_messages", on: inspector)).text.contains("Cut at"))

        inspector.console = [entry(String(repeating: "a", count: width + 1))]
        #expect(
            (await call("console_messages", on: inspector)).text.contains(
                "Cut at \(width) of \(width + 1) characters; the rest cannot be read again."))
    }

    @Test("A request with more headers than may be listed lists the first ones and says so")
    func headersAreBounded() async {
        let headers = (0..<400).map { HTTPHeader(name: "h\($0)", value: "v") }
        let inspector = FakeInspector()
        inspector.network = [NetworkEntry(id: "1", method: "GET", url: "https://example.com/", status: 200, requestHeaders: headers)]
        let result = await call("network_requests", ["include_headers": true], on: inspector)
        let maximum = ToolCatalog.headersPerDirection
        #expect(result.text.contains("[Cut at \(maximum) of 400 headers; the rest cannot be read again.]"))
        #expect(result.text.contains("h\(maximum - 1): v") && !result.text.contains("h\(maximum): v"))
    }

    @Test("Clearing the console does not promise a next page that no longer exists")
    func clearedConsole() async {
        let inspector = Self.console.inspector(30)
        let result = await call("console_messages", ["limit": .int(10), "clear": true], on: inspector)
        #expect(result.text.hasPrefix("Showing 1–10 of 30 console messages. The history was cleared, so the rest cannot be read again.\n\n"))
        #expect(!result.text.contains("Pass offset"))
        #expect(inspector.clearedConsole)

        let whole = await call("console_messages", ["limit": .int(30), "clear": true], on: inspector)
        #expect(!whole.text.contains("cleared"))
    }

    @Test("open_url clips a long title and says where to read it whole; a title at the width is not clipped")
    func openedTitle() async {
        let width = ToolCatalog.titleWidth
        let exact = Format().opened(PageInfo(url: "https://example.com/", title: String(repeating: "t", count: width)))
        #expect(!exact.contains("clipped"))
        let over = Format().opened(PageInfo(url: "https://example.com/", title: String(repeating: "t", count: width + 1)))
        #expect(over.hasPrefix("Title is clipped to \(width) characters in each row. Read one in full with page_elements.\n\n"))
        #expect(over.hasSuffix(String(repeating: "t", count: width) + "…"))

        let url = "https://example.com/" + String(repeating: "u", count: ToolCatalog.largestURLWidth)
        let long = Format().opened(PageInfo(url: url, title: "T"))
        #expect(long.contains("Cut at \(ToolCatalog.largestURLWidth) of \(url.count) characters; the rest cannot be read again."))
        #expect(long.utf16.count < ToolStandard.usualPage)
    }

    @Test("An element over the size this server reads is refused with its size and what to do")
    func elementTooLarge() async {
        let inspector = FakeInspector()
        inspector.failure = .elementTooLarge(size: ToolCatalog.largestElement + 1)
        let result = await call("page_elements", on: inspector)
        #expect(result.isError)
        #expect(result.text.contains("holds \(ToolCatalog.largestElement + 1) characters, more than the \(ToolCatalog.largestElement)"))
        #expect(result.text.contains("Pass a selector that matches a smaller element."))
    }

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // Each row lists twenty headers at their widest, so a page of sixty cannot fit.
        let headers = (0..<20).map {
            HTTPHeader(
                name: Self.filled("h\($0)-", to: ToolCatalog.nameWidth),
                value: String(repeating: "v", count: ToolCatalog.headerValueWidth))
        }
        let inspector = FakeInspector()
        inspector.network = (0..<60).map {
            NetworkEntry(
                id: "id-\(Self.padded($0))", method: "GET", url: "https://example.com/row-\(Self.padded($0))-",
                status: 200, requestHeaders: headers, responseHeaders: headers)
        }
        let maximum = ToolCatalog.networkLimitRange.upperBound
        var offset = 0
        var seen: [Int] = []
        while offset < 60 {
            let result = await call(
                "network_requests",
                ["include_headers": true, "limit": .int(maximum), "offset": .int(offset)], on: inspector)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<60).filter { result.text.contains("row-\(Self.padded($0))-") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < maximum)
            let next = last + 1 < 60 ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) of 60 requests. \(next)\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<60))
    }

    // MARK: Windows

    private static let html = String((0..<30_000).map { Character(UnicodeScalar(97 + UInt8($0 % 26))) })

    private func inspectorWithElement(_ text: String = html) -> FakeInspector {
        let inspector = FakeInspector()
        inspector.elementsResult = ElementsResult(matchCount: 1, html: text)
        inspector.bodyText = text
        return inspector
    }

    /// The data after the notices and the line that says what matched.
    private func data(of text: String) -> String {
        String(text.split(separator: "\n\n", maxSplits: 2, omittingEmptySubsequences: false).last ?? "")
    }

    @Test("A long element comes as one default window, announced before the data")
    func defaultWindow() async {
        let size = ToolCatalog.defaultMaxCharacters
        let result = await call("page_elements", on: inspectorWithElement())
        #expect(result.text.hasPrefix("Characters 1–\(size) of 30000. Pass character_offset=\(size) for the rest.\n\n1 match for 'html'; it is below:\n\n"))
        #expect(data(of: result.text) == String(Self.html.prefix(size)))
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole text", arguments: [ToolCatalog.elementsName, ToolCatalog.bodyName])
    private func windowsChain(_ tool: String) async {
        let inspector = inspectorWithElement()
        var offset = 0
        var joined = ""
        while offset < Self.html.count {
            var arguments: [String: Value] = ["character_offset": .int(offset), "max_characters": .int(7_000)]
            if tool == ToolCatalog.bodyName { arguments["request_id"] = "r1" }
            let result = await call(tool, arguments, on: inspector)
            let window = data(of: result.text)
            let last = offset + window.count
            let next = last < Self.html.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("Characters \(offset + 1)–\(last) of 30000. \(next)\n\n"))
            #expect(window.count == min(7_000, Self.html.count - offset))
            joined += window
            offset = last
        }
        #expect(joined == Self.html)
    }

    @Test("A text that fits one window carries no notice, and an offset past the end says so")
    func shortTextAndPastTheEnd() async {
        let inspector = inspectorWithElement("<p>short</p>")
        let whole = await call("page_elements", on: inspector)
        #expect(whole.text == "1 match for 'html'; it is below:\n\n<p>short</p>")

        let past = await call("page_elements", ["character_offset": .int(40)], on: inspector)
        #expect(past.text.hasPrefix("Characters 0 of 12: character_offset=40 is past the end. That is all."))
    }

    @Test("max_characters and character_offset one past their ranges are moved, and the result says which")
    func windowArgumentsOutsideTheirRanges() async {
        let inspector = inspectorWithElement()
        let range = ToolCatalog.maxCharactersRange
        let over = await call("page_elements", ["max_characters": .int(range.upperBound + 1)], on: inspector)
        #expect(over.text.hasPrefix("max_characters=\(range.upperBound + 1) is outside 1–\(range.upperBound); \(range.upperBound) was used.\nCharacters 1–\(range.upperBound) of 30000."))
        #expect(over.text.utf16.count <= ToolStandard.longestResult)

        let under = await call("network_response_body", ["request_id": "r1", "max_characters": .int(0)], on: inspector)
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(range.upperBound); 1 was used.\nCharacters 1–1 of 30000."))

        let negative = await call("page_elements", ["character_offset": .int(-5)], on: inspector)
        #expect(negative.text.hasPrefix("character_offset=-5 is outside 0–\(ToolCatalog.offsetRange.upperBound); 0 was used.\n"))
    }

    @Test("A window of characters that take several UTF-16 units each holds fewer and says where to resume")
    func wideWindowShrinks() async {
        let family = "👨‍👩‍👧"
        let text = String(repeating: family, count: 20_000)
        #expect(text.utf16.count > ToolStandard.longestResult)
        let result = await call(
            "page_elements", ["max_characters": .int(20_000)], on: inspectorWithElement(text))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(result.text.contains("Pass character_offset="))
        #expect(!result.text.contains("Cut at \(ToolStandard.longestResult)"))
    }

    @Test("A binary body says it is base64, before the data")
    func base64Body() async {
        let inspector = inspectorWithElement("QUJD")
        inspector.bodyIsBase64 = true
        let result = await call("network_response_body", ["request_id": "r1"], on: inspector)
        #expect(result.text == "Binary body, base64-encoded.\n\nQUJD")
    }

    // MARK: Screenshots

    private func image(_ output: ToolOutput) -> (data: String, mimeType: String)? {
        let images = output.content.compactMap { block -> (String, String)? in
            if case .image(let data, let mimeType) = block { return (data, mimeType) }
            return nil
        }
        return images.count == 1 ? images[0] : nil
    }

    private func pixels(_ base64: String) -> (width: Int, height: Int)? {
        guard let data = Data(base64Encoded: base64), data.count > 24 else { return nil }
        // A PNG header holds the size at fixed places; a JPEG is measured by decoding.
        if data.starts(with: [0x89, 0x50]) {
            let word = { (at: Int) in data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
            return (word(16), word(20))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }

    @Test("A screenshot inside the limits is sent as it came, with no notice")
    func screenshotInsideTheLimits() async throws {
        let inspector = FakeInspector()
        inspector.screenshotData = FakeInspector.png(width: ToolCatalog.largestScreenshotSide, height: 100)
        let result = await call("page_screenshot", on: inspector)
        #expect(result.content.count == 1)
        #expect(try #require(image(result)).data == inspector.screenshotData)
    }

    @Test("A screenshot one pixel too wide or too tall is scaled to the limit, and a line says so")
    func screenshotScaled() async throws {
        let side = ToolCatalog.largestScreenshotSide
        for (width, height) in [(side + 1, 400), (400, side + 1)] {
            let inspector = FakeInspector()
            inspector.screenshotData = FakeInspector.png(width: width, height: height)
            let result = await call("page_screenshot", on: inspector)
            let sent = try #require(image(result))
            let size = try #require(pixels(sent.data))
            #expect(max(size.width, size.height) == side)
            #expect(result.text.hasPrefix("The viewport was \(width)×\(height) pixels; the image is "))
        }
    }

    @Test("A screenshot over the byte limit is re-encoded to fit it")
    func screenshotTooHeavy() async throws {
        let inspector = FakeInspector()
        inspector.screenshotData = FakeInspector.png(width: 1_500, height: 1_000, noise: true)
        let original = try #require(Data(base64Encoded: inspector.screenshotData)).count
        #expect(original > ToolCatalog.largestScreenshotBytes)
        let result = await call("page_screenshot", on: inspector)
        let sent = try #require(image(result))
        #expect(try #require(Data(base64Encoded: sent.data)).count <= ToolCatalog.largestScreenshotBytes)
        #expect(max(try #require(pixels(sent.data)).width, 0) <= ToolCatalog.largestScreenshotSide)
        #expect(result.text.contains("scaled to fit"))
    }

    @Test("Something that is not an image is refused, not passed on")
    func screenshotUnreadable() async {
        let inspector = FakeInspector()
        inspector.screenshotData = "AAAA"
        let result = await call("page_screenshot", on: inspector)
        #expect(result.isError)
    }

    // MARK: Arguments

    @Test("An argument the schema does not list is refused, with the names that are allowed")
    func unknownArguments() async {
        let renamed = await call("page_elements", ["limit": .int(5)], on: FakeInspector())
        #expect(renamed.isError)
        #expect(renamed.text.contains("Argument 'limit' is not valid"))
        #expect(renamed.text.contains("character_offset, max_characters, selector"))

        let none = await call("firefox_status", ["verbose": true], on: FakeInspector())
        #expect(none.isError)
        #expect(none.text.contains("this tool takes no arguments"))
    }

    @Test("A wrong type is refused with the form expected")
    func wrongTypes() async {
        let inspector = FakeInspector()
        for (tool, arguments, expected) in [
            ("console_messages", ["limit": Value.string("many")], "a whole number was expected"),
            ("console_messages", ["clear": "yes"], "true or false was expected"),
            ("console_messages", ["level": "fatal"], "expected one of: debug, info, warn, error"),
            ("page_elements", ["selector": 5], "text was expected"),
            ("network_requests", ["offset": 1.5], "a whole number was expected"),
            ("network_response_body", ["request_id": 7], "text was expected"),
        ] as [(String, [String: Value], String)] {
            let result = await call(tool, arguments, on: inspector)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments)")
        }
    }

    @Test("An error repeats only the start of a caller's text, and stays within its limit")
    func errorsEchoLittle() async {
        let long = String(repeating: "q", count: 5_000)
        let unknown = await call("page_elements", [long: 1], on: FakeInspector())
        let tool = await call(long, on: FakeInspector())
        let scheme = await call("open_url", ["url": .string("ftp://" + long)], on: FakeInspector())
        for result in [unknown, tool, scheme] {
            #expect(result.isError)
            #expect(result.text.utf16.count < ToolStandard.longestError)
            #expect(!result.text.contains(String(repeating: "q", count: ToolStandard.echoWidth + 1)))
        }
    }

    // MARK: Time

    @Test("A call that outlasts its deadline is answered with an error that says how to ask for less")
    func deadline() async {
        let inspector = FakeInspector()
        inspector.openDelay = .seconds(5)
        let result = await InspectTools(inspector: inspector, timeout: .seconds(1)).handle(
            .init(name: "open_url", arguments: ["url": "https://example.com/"]))
        #expect(result.isError)
        #expect(result.text.contains("did not finish within 1 seconds"))
        #expect(result.text.contains("may still be loading"))
        #expect(ToolCatalog.deadline < ToolStandard.timeLimit)
    }

    // MARK: The texts the model reads

    @Test("The instructions and every description are within their limit, as sent")
    func descriptionsWithinTheirLimit() {
        #expect(
            ToolStandard.overlongTexts(instructions: InspectMCPServer.instructions, catalog: ToolCatalog.all()).isEmpty)
    }

    @Test("Every bound a text quotes is the constant the code enforces")
    func statedBoundsMatchTheCode() {
        let descriptions = Dictionary(uniqueKeysWithValues: ToolCatalog.all().map { ($0.name, $0.description ?? "") })
        #expect(descriptions[ToolCatalog.consoleName]!.contains("up to \(ToolCatalog.consoleLimitRange.upperBound)"))
        #expect(descriptions[ToolCatalog.networkName]!.contains("up to \(ToolCatalog.networkLimitRange.upperBound)"))
        #expect(descriptions[ToolCatalog.storageName]!.contains("up to \(ToolCatalog.storageLimitRange.upperBound)"))
        #expect(descriptions[ToolCatalog.elementsName]!.contains("up to \(ToolCatalog.maxCharactersRange.upperBound)"))
        #expect(descriptions[ToolCatalog.bodyName]!.contains("up to \(ToolCatalog.maxCharactersRange.upperBound)"))
        #expect(descriptions[ToolCatalog.consoleName]!.contains("\(EventBuffer.consoleCapacity)"))
        #expect(descriptions[ToolCatalog.networkName]!.contains("\(EventBuffer.networkCapacity)"))
        for (tool, constant) in [
            (ToolCatalog.console, ToolCatalog.defaultConsoleLimit),
            (ToolCatalog.network, ToolCatalog.defaultNetworkLimit),
            (ToolCatalog.storage, ToolCatalog.defaultStorageLimit),
        ] {
            #expect((tool.description ?? "").contains("\(constant) "), "\(tool.name)")
        }

        let schema = ToolCatalog.console.inputSchema.objectValue?["properties"]?.objectValue?["limit"]?.objectValue
        #expect(schema?["maximum"]?.intValue == ToolCatalog.consoleLimitRange.upperBound)
        #expect(schema?["default"]?.intValue == ToolCatalog.defaultConsoleLimit)
    }

    @Test("The manifest and the server carry the same version, and the manifest lists every tool")
    func manifestAgrees() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            Value.self, from: Data(contentsOf: root.appendingPathComponent("extension/manifest.json")))
        #expect(manifest.objectValue?["version"]?.stringValue == InspectMCPServer.version)
        let listed = manifest.objectValue?["tools"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(Set(listed ?? []) == Set(ToolCatalog.all().map(\.name)))
    }
}
