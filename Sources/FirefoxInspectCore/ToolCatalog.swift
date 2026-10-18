import Foundation
import MCP

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

    private static func boolean(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
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

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "Firefox status",
        description: """
            Reports whether Firefox is installed where this server expects it and whether \
            the browser it controls is running. Starts nothing.

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
            title.

            This is a separate, temporary Firefox with an empty profile: no logins, no \
            cookies, no history, no extensions. It cannot see the tabs the person is \
            using. Only http and https URLs are opened.

            Opening a page clears the console and network history, so the other tools \
            describe the page just loaded.
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
            matched. The default selector is "html", the whole document.

            This is the Elements panel's DOM, not the source the server sent. Long \
            output is cut and says so.
            """,
        inputSchema: object(properties: [
            "selector": string("CSS selector. Defaults to \"html\"."),
            "max_characters": integer(
                "Longest HTML to return.", range: 100...Configuration.characterLimit,
                default: 10_000),
        ]),
        annotations: readOnly
    )

    static let console = Tool(
        name: consoleName,
        title: "Read console messages",
        description: """
            Returns what the loaded page wrote to the console (console.log, warn, error) \
            and its uncaught JavaScript errors, oldest first, since the last open_url.

            Only messages written after the page started loading are available; the \
            browser does not keep earlier history. At most 500 are kept.
            """,
        inputSchema: object(properties: [
            "level": string("Only this level: debug, info, warn or error."),
            "limit": integer(
                "Most entries to return, newest kept.", range: Configuration.listLimitRange,
                default: Configuration.defaultListLimit),
            "clear": boolean("Forget the messages after reading them."),
        ]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
    )

    static let network = Tool(
        name: networkName,
        title: "List network requests",
        description: """
            Lists the requests the loaded page made since the last open_url: method, URL, \
            status, type, size and duration, in the order they started. Each has an id for \
            network_response_body. Headers are included only when asked for.
            """,
        inputSchema: object(properties: [
            "url_contains": string("Only requests whose URL contains this text."),
            "include_headers": boolean("Also list request and response headers."),
            "limit": integer(
                "Most requests to return.", range: Configuration.listLimitRange,
                default: Configuration.defaultListLimit),
        ]),
        annotations: readOnly
    )

    static let responseBody = Tool(
        name: bodyName,
        title: "Read a response body",
        description: """
            Returns the body of one request from network_requests. Binary bodies come back \
            as base64. Not available for redirects, cached responses or bodies over 5 MB. \
            Long bodies are cut and say so.
            """,
        inputSchema: object(
            properties: [
                "request_id": string("The id shown by network_requests."),
                "max_characters": integer(
                    "Longest body to return.", range: 100...Configuration.characterLimit,
                    default: 10_000),
            ], required: ["request_id"]),
        annotations: readOnly
    )

    static let storage = Tool(
        name: storageName,
        title: "Read page storage",
        description: """
            Returns the cookies (HttpOnly ones included), localStorage and sessionStorage of \
            the loaded page's browser. The profile is empty apart from what pages loaded in \
            it have set.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly
    )

    static let screenshot = Tool(
        name: screenshotName,
        title: "Screenshot the page",
        description: "Returns a PNG of the loaded page's viewport.",
        inputSchema: object(properties: [:]),
        annotations: readOnly
    )
}
