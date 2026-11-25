import Foundation

/// Settings arrive as command-line arguments, which is how a Claude extension passes
/// `user_config`. Hand-rolled: the whole surface is one flag, and every dependency here
/// has to earn its place.
public struct Configuration: Sendable, Equatable {
    public var firefoxPath: String = "/Applications/Firefox.app/Contents/MacOS/firefox"

    public init() {}

    /// The host leaves `${user_config.key}` untouched when a setting was left empty, so
    /// the literal text arrives as an argument and must be ignored, not used as a path.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// Unknown flags are ignored rather than fatal: a server that will not launch is much
    /// harder to diagnose than one running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--firefox-path", index + 1 < arguments.count {
                let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !isPlaceholder(value) { configuration.firefoxPath = value }
                index += 2
            } else {
                index += 1
            }
        }
        return configuration
    }
}
