import Foundation

/// Plain-text rendering of what the tools return. Page content is untrusted, so each
/// block says where it came from rather than blending into the surrounding text.
struct Format {

    func status(_ status: BrowserStatus) -> String {
        """
        Firefox: \(status.executableExists ? "found" : "NOT FOUND") at \(status.executablePath)
        Browser: \(status.isRunning ? "running" : "not started (starts on the first open_url)")\
        \(status.version.map { "\nVersion: \($0)" } ?? "")
        """
    }

    func opened(_ page: PageInfo) -> String {
        "Loaded \(page.url)\nTitle: \(page.title)"
    }

    func elements(_ result: ElementsResult, selector: String) -> String {
        guard result.matchCount > 0 else { return "No element matches '\(selector)'." }
        return """
            \(result.matchCount) match\(result.matchCount == 1 ? "" : "es") for '\(selector)'; \
            first one below\(result.isTruncated ? " (cut — raise max_characters for more)" : ""):

            \(result.html)
            """
    }

    func console(_ entries: [ConsoleEntry], total: Int) -> String {
        guard !entries.isEmpty else { return "No console messages." }
        let lines = entries.map { entry in
            let time = entry.timestamp.formatted(.dateTime.hour().minute().second())
            let origin = entry.source == "javascript" ? " (uncaught)" : ""
            return "[\(entry.level)]\(origin) \(time) \(entry.text)"
        }
        let header = entries.count < total ? "Showing the newest \(entries.count) of \(total):\n" : ""
        return header + lines.joined(separator: "\n")
    }

    func network(_ entries: [NetworkEntry], total: Int, includeHeaders: Bool) -> String {
        guard !entries.isEmpty else { return "No requests." }
        let lines = entries.map { entry -> String in
            var line = "\(entry.id)  \(entry.method)  "
            if let failure = entry.failure {
                line += "FAILED (\(failure))"
            } else if let status = entry.status {
                line += "\(status)"
            } else {
                line += "pending"
            }
            if let type = entry.mimeType, !type.isEmpty { line += "  \(type)" }
            if let bytes = entry.bytes { line += "  \(bytes) B" }
            if let ms = entry.durationMilliseconds { line += "  \(ms) ms" }
            line += "  \(entry.url.isEmpty ? "(no URL reported)" : entry.url)"
            if includeHeaders {
                line += headerBlock("request", entry.requestHeaders)
                line += headerBlock("response", entry.responseHeaders)
            }
            return line
        }
        let header = entries.count < total ? "Showing \(entries.count) of \(total):\n" : ""
        return header + lines.joined(separator: "\n")
    }

    private func headerBlock(_ label: String, _ headers: [HTTPHeader]) -> String {
        guard !headers.isEmpty else { return "" }
        return "\n    \(label) headers:\n"
            + headers.map { "      \($0.name): \($0.value)" }.joined(separator: "\n")
    }

    func body(_ body: ResponseBody) -> String {
        var note = ""
        if body.isBase64 { note += "Binary body, base64-encoded.\n" }
        if body.isTruncated { note += "Cut — raise max_characters for more.\n" }
        return note + body.text
    }

    func storage(_ snapshot: StorageSnapshot) -> String {
        var out = "Cookies (\(snapshot.cookies.count)):\n"
        out +=
            snapshot.cookies.isEmpty
            ? "  none\n"
            : snapshot.cookies.map {
                "  \($0.name)=\($0.value)  [\($0.domain)\($0.path)\($0.isHTTPOnly ? ", HttpOnly" : "")\($0.isSecure ? ", Secure" : "")]"
            }.joined(separator: "\n") + "\n"
        out += "\nlocalStorage (\(snapshot.local.count)):\n" + pairs(snapshot.local)
        out += "\nsessionStorage (\(snapshot.session.count)):\n" + pairs(snapshot.session)
        return out
    }

    private func pairs(_ values: [String: String]) -> String {
        values.isEmpty
            ? "  none\n"
            : values.sorted { $0.key < $1.key }.map { "  \($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
    }
}
