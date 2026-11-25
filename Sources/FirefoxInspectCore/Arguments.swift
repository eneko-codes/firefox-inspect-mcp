import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool hands `notices` to `Format`, which puts them before the data.
public final class Arguments {
    private let values: [String: Value]

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    /// Refuses an argument the tool's schema does not list, with the names that are
    /// allowed, so a call that still uses a renamed argument fails instead of running
    /// without it.
    public func refuseUnknown(allowed: [String]) throws {
        guard let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) else { return }
        let names = allowed.sorted()
        throw InspectError.badArgument(
            name: unknown,
            reason: names.isEmpty
                ? "this tool takes no arguments"
                : "it is not an argument of this tool; the arguments are: " + names.joined(separator: ", "))
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    public func requiredString(_ name: String) throws -> String {
        guard let text = try optionalString(name) else {
            if given(name) == nil { throw InspectError.missingArgument(name) }
            throw InspectError.badArgument(name: name, reason: "it is empty")
        }
        return text
    }

    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw InspectError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw InspectError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// One of a fixed set of words, compared case-insensitively; `nil` when not given.
    public func optionalChoice(_ name: String, among allowed: [String]) throws -> String? {
        guard let text = try optionalString(name)?.lowercased() else { return nil }
        guard allowed.contains(text) else {
            throw InspectError.badArgument(
                name: name, reason: "expected one of: " + allowed.joined(separator: ", "))
        }
        return text
    }

    /// A quantity: a size, a count, a position. Outside its range it is moved to the
    /// nearest allowed value, and `notices` gains the sentence that says which was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = given(name) else { return fallback }
        guard let number = raw.intValue else {
            throw InspectError.badArgument(name: name, reason: "a whole number was expected")
        }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    /// The `character_offset` and `max_characters` of a window on one long text.
    public func window() throws -> (characterOffset: Int, maxCharacters: Int) {
        (
            try int("character_offset", default: 0, in: ToolCatalog.offsetRange),
            try int(
                "max_characters", default: ToolCatalog.defaultMaxCharacters,
                in: ToolCatalog.maxCharactersRange)
        )
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
