import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// There is deliberately no tool that runs caller-supplied JavaScript. The inspection
/// scripts are fixed and take their input as arguments, never as code.
public enum ToolCatalog {
    public static let statusName = "firefox_status"
    public static let openURLName = "open_url"
    public static let elementsName = "page_elements"
    public static let consoleName = "console_messages"
    public static let networkName = "network_requests"
    public static let bodyName = "network_response_body"
    public static let storageName = "page_storage"
    public static let screenshotName = "page_screenshot"

    // MARK: Bounds
    //
    // The schemas, the descriptions and the server instructions quote these by
    // interpolation. Each row maximum is chosen so that a page of the widest rows still fits
    // `ToolStandard.longestResult` (`BoundsTests` renders one), and each default makes a call
    // with no optional argument about `ToolStandard.usualPage` or less.

    /// How long a call may take before it is abandoned. Under `ToolStandard.timeLimit`, and
    /// above the 30 seconds one browser command may take, so a slow page is reported by
    /// this server and not by the client's generic "no result".
    public static let deadline = Duration.seconds(120)

    public static let offsetRange = 0...10_000_000

    public static let consoleLimitRange = 1...80
    public static let defaultConsoleLimit = 25
    public static let networkLimitRange = 1...60
    public static let defaultNetworkLimit = 15
    public static let storageLimitRange = 1...40
    public static let defaultStorageLimit = 15

    /// The window on one long text. The maximum is half the longest result, which leaves
    /// room for the notices around it and for text whose characters take several UTF-16
    /// units.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// The longest element `page_elements` reads, in characters. Beyond it the call is
    /// refused: the whole element crosses the browser's socket before it is windowed.
    public static let largestElement = 10_000_000

    /// How wide a field of a row may be before it is clipped. Whatever is clipped cannot
    /// be read again: no tool reads one console message, URL, cookie or stored value whole.
    public static let consoleTextWidth = 300
    public static let urlWidth = 300
    public static let headerValueWidth = 200
    public static let storageValueWidth = 300
    /// Headers listed for one request, in each direction.
    public static let headersPerDirection = 40
    public static let nameWidth = 100
    public static let titleWidth = 300
    public static let largestURLWidth = 2_000

    /// A screenshot is at most this many pixels on its long side and this many bytes.
    public static let largestScreenshotSide = 1568
    public static let largestScreenshotBytes = 1_500_000

    public static let consoleLevels = ["debug", "info", "warn", "error"]

    /// The argument names a tool's schema lists, which is what `Arguments.refuseUnknown`
    /// holds a call to.
    public static func argumentNames(of toolName: String) -> [String]? {
        all().first { $0.name == toolName }?.inputSchema.objectValue?["properties"]?.objectValue?
            .keys.sorted()
    }

    public static func all() -> [Tool] {
        [status, openURL, elements, console, network, responseBody, storage, screenshot]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    /// `type` is always a single string, never a union: Claude Desktop's schema
    /// sanitiser drops a property whose `type` is an array. Omit an optional field
    /// rather than passing null.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String, default def: Bool) -> Value {
        .object([
            "type": .string("boolean"), "description": .string(description), "default": .bool(def),
        ])
    }

    private static func choice(_ description: String, _ values: [String]) -> Value {
        .object([
            "type": .string("string"), "description": .string(description),
            "enum": .array(values.map { .string($0) }),
        ])
    }

    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
            "default": .int(def),
        ])
    }

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Most \(things) in one page.", range: range, default: def)
    }

    private static let offset = integer(
        "Rows to skip; the notice at the top of a page gives the value for the next one.",
        range: offsetRange, default: 0)

    private static let characterOffset = integer(
        "Characters to skip; the notice at the top of a window gives the value for the next one.",
        range: offsetRange, default: 0)

    private static let maxCharacters = integer(
        "Most characters in one window.", range: maxCharactersRange, default: defaultMaxCharacters)

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "Firefox status",
        description: """
            Reports whether Firefox is installed where this server expects it and whether \
            the browser it controls is running. A few lines. Starts nothing.

            Use it when another tool fails, or when setting the server up.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly
    )

    static let openURL = Tool(
        name: openURLName,
        title: "Open a URL for inspection",
        description: """
            Loads a web page in the Firefox this server controls, starting it first if \
            needed, and waits for the page to finish loading. Returns the final URL and \
            title (the title is clipped to \(titleWidth) characters; page_elements with the \
            selector "title" reads it whole).

            This is a separate, temporary Firefox with an empty profile: no logins, no \
            cookies, no history, no extensions. It cannot see the tabs the person is \
            using. Only http and https URLs are opened.

            Opening a page clears the console and network history, so the other tools \
            describe the page just loaded. A page that has not finished loading after \
            \(deadline.components.seconds) seconds is reported as a timeout.
            """,
        inputSchema: object(
            properties: ["url": string("The http or https URL to load.")], required: ["url"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
    )

    static let elements = Tool(
        name: elementsName,
        title: "Inspect page elements",
        description: """
            Returns the HTML of the first element matching a CSS selector in the loaded \
            page, as the browser holds it after scripts have run, plus how many elements \
            matched. The default selector is "html", the whole document. Returns the first \
            \(defaultMaxCharacters) characters of it; a notice at the top says how many \
            exist and the character_offset that returns the next window (up to \
            \(maxCharactersRange.upperBound) characters each with max_characters).

            This is the Elements panel's DOM, not the source the server sent. To reach \
            another match, narrow the selector (for example with :nth-of-type). An element \
            of more than \(largestElement) characters is refused: pass a selector for a \
            smaller one.
            """,
        inputSchema: object(properties: [
            "selector": string("CSS selector. Defaults to \"html\"."),
            "character_offset": characterOffset,
            "max_characters": maxCharacters,
        ]),
        annotations: readOnly
    )

    static let console = Tool(
        name: consoleName,
        title: "Read console messages",
        description: """
            Returns what the loaded page wrote to the console (console.log, warn, error) \
            and its uncaught JavaScript errors since the last open_url, oldest first, \
            \(defaultConsoleLimit) to a page. A notice at the top says how many exist and \
            the offset for the next page; pass limit (up to \(consoleLimitRange.upperBound)) \
            and offset for more.

            Only messages written after the page started loading are available; the \
            browser does not keep earlier history. At most \(EventBuffer.consoleCapacity) are \
            kept: when more arrive the oldest are dropped, and a notice says how many. Each \
            message is clipped to \(consoleTextWidth) characters, and the rest cannot be read \
            again. With clear=true the whole history is forgotten after this page, so rows \
            beyond it cannot be read again.
            """,
        inputSchema: object(properties: [
            "level": choice("Only this level.", consoleLevels),
            "limit": limit("messages", range: consoleLimitRange, default: defaultConsoleLimit),
            "offset": offset,
            "clear": boolean(
                "Forget every message after reading this page, including those not on it.",
                default: false),
        ]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
    )

    static let network = Tool(
        name: networkName,
        title: "List network requests",
        description: """
            Lists the requests the loaded page made since the last open_url: id, method, \
            status, type, size, duration and URL, in the order they started, \
            \(defaultNetworkLimit) to a page. A notice at the top says how many exist and \
            the offset for the next page; pass limit (up to \(networkLimitRange.upperBound)) \
            and offset for more. Each has an id for network_response_body. Headers are \
            included only with include_headers.

            At most \(EventBuffer.networkCapacity) requests are kept: when more arrive the \
            oldest are dropped, and a notice says how many. URLs and header values are \
            clipped (\(urlWidth) and \(headerValueWidth) characters), at most \(headersPerDirection) \
            headers are listed in each direction, and the rest cannot be read again.
            """,
        inputSchema: object(properties: [
            "url_contains": string("Only requests whose URL contains this text."),
            "include_headers": boolean("Also list request and response headers.", default: false),
            "limit": limit("requests", range: networkLimitRange, default: defaultNetworkLimit),
            "offset": offset,
        ]),
        annotations: readOnly
    )

    static let responseBody = Tool(
        name: bodyName,
        title: "Read a response body",
        description: """
            Returns the body of one request from network_requests: its first \
            \(defaultMaxCharacters) characters. A notice at the top says how many exist and \
            the character_offset that returns the next window (up to \
            \(maxCharactersRange.upperBound) characters each with max_characters). Binary \
            bodies come back as base64.

            Not available for redirects, cached responses or bodies over 5 MB.
            """,
        inputSchema: object(
            properties: [
                "request_id": string("The id shown by network_requests."),
                "character_offset": characterOffset,
                "max_characters": maxCharacters,
            ], required: ["request_id"]),
        annotations: readOnly
    )

    static let storage = Tool(
        name: storageName,
        title: "Read page storage",
        description: """
            Returns the cookies (HttpOnly ones included), localStorage and sessionStorage of \
            the loaded page's browser, \(defaultStorageLimit) entries to a page: cookies by \
            domain, path and name, then localStorage and sessionStorage by key. A notice at \
            the top says how many exist and the offset for the next page; pass limit (up to \
            \(storageLimitRange.upperBound)) and offset for more. Names are clipped to \
            \(nameWidth) characters and values to \(storageValueWidth), and the rest cannot \
            be read again.

            The profile is empty apart from what pages loaded in it have set.
            """,
        inputSchema: object(properties: [
            "limit": limit("entries", range: storageLimitRange, default: defaultStorageLimit),
            "offset": offset,
        ]),
        annotations: readOnly
    )

    static let screenshot = Tool(
        name: screenshotName,
        title: "Screenshot the page",
        description: """
            Returns one image: the loaded page's viewport, as a PNG. It is scaled down to at \
            most \(largestScreenshotSide) pixels on its long side and \(largestScreenshotBytes) \
            bytes (re-encoded as JPEG if a PNG that size does not fit), and a line of text \
            says so when it was. The part of the page outside the viewport is not captured.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly
    )
}
