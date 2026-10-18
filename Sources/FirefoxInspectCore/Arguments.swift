import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
public struct Arguments {
    private let values: [String: Value]

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw InspectError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw InspectError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// Clamps rather than rejects: a model asking for 5000 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw InspectError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    // MARK: URLs

    /// `javascript:` is script execution wearing a URL, `file:` reaches the disk and
    /// `data:` carries its payload inline. Only web pages are opened.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    private static let refusedSchemeNames: Set<String> = [
        "javascript", "data", "file", "blob", "about", "view-source", "chrome", "resource",
    ]

    /// A string with no scheme is treated as https, which is what "open example.com"
    /// means. Matched by hand rather than with `URLComponents`: a bare `example.com/a:b`
    /// parses as the scheme `example.com` under RFC 3986, and refusing it would be wrong.
    public static func validatedWebURL(_ raw: String, argument: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw InspectError.badArgument(name: argument, reason: "it is empty")
        }
        guard let colon = trimmed.firstIndex(of: ":") else { return "https://" + trimmed }
        let scheme = String(trimmed[trimmed.startIndex..<colon]).lowercased()
        let isSchemeShaped =
            !scheme.isEmpty && scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
            && scheme.first?.isLetter == true
        // `example.com:8080/x`: digits right after the colon, then a path, query or the end.
        let afterColon = trimmed[trimmed.index(after: colon)...]
        let port = afterColon.prefix(while: \.isNumber)
        // Named schemes win over the host:port reading, so `javascript:1` is refused.
        let isHostAndPort =
            isSchemeShaped && !port.isEmpty && !Self.refusedSchemeNames.contains(scheme)
            && (afterColon.dropFirst(port.count).first.map { "/?#".contains($0) } ?? true)
        guard isSchemeShaped, !isHostAndPort else { return "https://" + trimmed }
        guard allowedSchemes.contains(scheme) else {
            throw InspectError.unsupportedScheme(url: trimmed, scheme: scheme)
        }
        return trimmed
    }

    public func webURL(_ name: String) throws -> String {
        try Self.validatedWebURL(try requiredString(name), argument: name)
    }
}
