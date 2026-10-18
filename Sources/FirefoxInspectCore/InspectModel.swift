import Foundation

public struct PageInfo: Sendable, Equatable {
    public var url: String
    public var title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

public struct ConsoleEntry: Sendable, Equatable {
    /// `debug`, `info`, `warn` or `error`, as BiDi reports it.
    public var level: String
    /// `console` for a `console.*` call, `javascript` for an uncaught error.
    public var source: String
    public var text: String
    public var timestamp: Date

    public init(level: String, source: String, text: String, timestamp: Date) {
        self.level = level
        self.source = source
        self.text = text
        self.timestamp = timestamp
    }
}

public struct HTTPHeader: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct NetworkEntry: Sendable, Equatable {
    public var id: String
    public var method: String
    public var url: String
    public var status: Int?
    public var mimeType: String?
    public var bytes: Int?
    public var durationMilliseconds: Int?
    /// Firefox's error text when the request never completed, e.g. a DNS failure.
    public var failure: String?
    public var requestHeaders: [HTTPHeader]
    public var responseHeaders: [HTTPHeader]

    public init(
        id: String, method: String, url: String, status: Int? = nil, mimeType: String? = nil,
        bytes: Int? = nil, durationMilliseconds: Int? = nil, failure: String? = nil,
        requestHeaders: [HTTPHeader] = [], responseHeaders: [HTTPHeader] = []
    ) {
        self.id = id
        self.method = method
        self.url = url
        self.status = status
        self.mimeType = mimeType
        self.bytes = bytes
        self.durationMilliseconds = durationMilliseconds
        self.failure = failure
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
    }
}

public struct ElementsResult: Sendable, Equatable {
    public var matchCount: Int
    /// `outerHTML` of the first match, cut to the requested length.
    public var html: String
    public var isTruncated: Bool

    public init(matchCount: Int, html: String, isTruncated: Bool) {
        self.matchCount = matchCount
        self.html = html
        self.isTruncated = isTruncated
    }
}

public struct CookieInfo: Sendable, Equatable {
    public var name: String
    public var domain: String
    public var path: String
    public var value: String
    public var isHTTPOnly: Bool
    public var isSecure: Bool

    public init(
        name: String, domain: String, path: String, value: String, isHTTPOnly: Bool, isSecure: Bool
    ) {
        self.name = name
        self.domain = domain
        self.path = path
        self.value = value
        self.isHTTPOnly = isHTTPOnly
        self.isSecure = isSecure
    }
}

public struct StorageSnapshot: Sendable, Equatable {
    public var cookies: [CookieInfo]
    public var local: [String: String]
    public var session: [String: String]

    public init(cookies: [CookieInfo], local: [String: String], session: [String: String]) {
        self.cookies = cookies
        self.local = local
        self.session = session
    }
}

public struct ResponseBody: Sendable, Equatable {
    public var text: String
    /// True when the body was binary and `text` is its base64 form.
    public var isBase64: Bool
    public var isTruncated: Bool

    public init(text: String, isBase64: Bool, isTruncated: Bool) {
        self.text = text
        self.isBase64 = isBase64
        self.isTruncated = isTruncated
    }
}

public struct BrowserStatus: Sendable, Equatable {
    public var executablePath: String
    public var executableExists: Bool
    public var isRunning: Bool
    public var version: String?

    public init(
        executablePath: String, executableExists: Bool, isRunning: Bool, version: String?
    ) {
        self.executablePath = executablePath
        self.executableExists = executableExists
        self.isRunning = isRunning
        self.version = version
    }
}

/// What the tools need from a browser. The real one drives Firefox; the tests use a
/// double, so the suite never starts a browser.
public protocol BrowserInspector: Sendable {
    func status() async -> BrowserStatus
    /// Clears the console and network buffers, then loads the page.
    func open(url: String) async throws -> PageInfo
    func elements(selector: String, characterLimit: Int) async throws -> ElementsResult
    func consoleMessages(clear: Bool) async throws -> [ConsoleEntry]
    func networkRequests() async throws -> [NetworkEntry]
    func responseBody(requestID: String, characterLimit: Int) async throws -> ResponseBody
    func storage() async throws -> StorageSnapshot
    /// PNG, base64-encoded.
    func screenshot() async throws -> String
}
