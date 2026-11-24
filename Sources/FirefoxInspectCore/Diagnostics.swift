import Foundation

/// One line per event on stderr, the only channel an MCP host captures from a stdio
/// server. stdout is the JSON-RPC stream, so nothing here may ever print to it.
///
/// No function takes a message or a value from a request, so page content cannot get in
/// by construction. A line carries a fixed event, the tool name (checked to be a plain
/// identifier), the *kind* of an error (its type and case, never its payload) and a
/// duration. URLs, selectors, headers and console text are exactly what an inspector
/// handles, and none of them is ever logged.
public enum Diagnostics {

    static func started(version: String) {
        emit("info", "started version=\(version)")
    }

    static func browserStarted(since start: ContinuousClock.Instant) {
        emit("info", "browser started ms=\(milliseconds(since: start))")
    }

    static func toolFailed(_ name: String, error: Error, since start: ContinuousClock.Instant) {
        emit(
            "error",
            "tool=\(toolName(name)) failed error=\(kind(of: error)) ms=\(milliseconds(since: start))")
    }

    /// The client chooses this string, so it is only echoed when it looks like one of our
    /// own snake_case names; anything else, including a newline that would forge a second
    /// log line, becomes `invalid`.
    static func toolName(_ raw: String) -> String {
        let isIdentifier =
            !raw.isEmpty && raw.utf8.count <= 64
            && raw.unicodeScalars.allSatisfy {
                ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57)
                    || $0 == "_"
            }
        return isIdentifier ? raw : "invalid"
    }

    /// For an enum only what precedes the first parenthesis is used, because the
    /// associated values are where URLs and selectors live.
    static func kind(of error: Error) -> String {
        if Mirror(reflecting: error).displayStyle == .enum {
            return "\(type(of: error)).\(String(describing: error).prefix { $0 != "(" })"
        }
        let bridged = error as NSError
        return "\(bridged.domain)#\(bridged.code)"
    }

    static func line(
        _ level: String, _ event: String, at date: Date = Date(),
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> String {
        "\(date.formatted(.iso8601)) \(level) \(ProcessInfo.processInfo.processName)[\(processID)] \(event)\n"
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }

    // One write call per line. `try?` because the plain `write(_:)` raises an
    // Objective-C exception Swift cannot catch, and a diagnostic must never take the
    // server down.
    private static func emit(_ level: String, _ event: String) {
        try? FileHandle.standardError.write(contentsOf: Data(line(level, event).utf8))
    }
}
