import Foundation

/// Plain-text rendering of what the tools return. Page content is untrusted, so each
/// block says where it came from rather than blending into the surrounding text.
///
/// Every function that renders data takes the notices the call collected (a number moved
/// into its range) and puts them first, before the notices of what the result leaves out.
struct Format {

    // MARK: Clipping

    /// `text` as it may appear in a row: at most `width` characters. A clipped field ends
    /// in the standard's sentence for what can never be read again, because no tool of this
    /// server reads one console message, URL, header or stored value whole.
    static func clip(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        return String(text.prefix(width)) + "… [Cut at \(width) of \(text.count) characters; the rest cannot be read again.]"
    }

    // MARK: Fixed-size results

    func status(_ status: BrowserStatus) -> String {
        """
        Firefox: \(status.executableExists ? "found" : "NOT FOUND") at \(ToolStandard.echo(status.executablePath))
        Browser: \(status.isRunning ? "running" : "not started (starts on the first open_url)")\
        \(status.version.map { "\nVersion: \(ToolStandard.echo($0))" } ?? "")
        """
    }

    func opened(_ page: PageInfo) -> String {
        let clippedTitle = page.title.count > ToolCatalog.titleWidth
        let title = clippedTitle ? String(page.title.prefix(ToolCatalog.titleWidth)) + "…" : page.title
        let notice = clippedTitle
            ? [Notice.clipped(field: "Title", width: ToolCatalog.titleWidth, tool: ToolCatalog.elementsName)]
            : []
        return ToolStandard.withNotices(
            notice, "Loaded \(Self.clip(page.url, to: ToolCatalog.largestURLWidth))\nTitle: \(title)")
    }

    // MARK: Windows on one long text

    func elements(
        _ result: ElementsResult, selector: String, characterOffset: Int, maxCharacters: Int,
        notices: [String]
    ) -> String {
        guard result.matchCount > 0 else {
            return ToolStandard.withNotices(notices, "No element matches '\(ToolStandard.echo(selector))'.")
        }
        let matches =
            result.matchCount == 1
            ? "1 match for '\(ToolStandard.echo(selector))'; it is below:"
            : "\(result.matchCount) matches for '\(ToolStandard.echo(selector))'; the first is below (narrow the selector to reach another):"
        return ToolStandard.fitting(maxCharacters) { size in
            let window = ToolStandard.window(
                of: result.html, characterOffset: characterOffset, maxCharacters: size)
            return ToolStandard.withNotices(
                notices + [window.notice].compactMap { $0 }, matches + "\n\n" + window.text)
        }
    }

    func body(
        _ body: ResponseBody, characterOffset: Int, maxCharacters: Int, notices: [String]
    ) -> String {
        let encoding = body.isBase64 ? ["Binary body, base64-encoded."] : []
        return ToolStandard.fitting(maxCharacters) { size in
            let window = ToolStandard.window(
                of: body.text, characterOffset: characterOffset, maxCharacters: size)
            return ToolStandard.withNotices(
                notices + encoding + [window.notice].compactMap { $0 }, window.text)
        }
    }

    // MARK: Listings

    func console(
        _ rows: [ConsoleEntry], total: Int, dropped: Int, limit: Int, offset: Int, cleared: Bool,
        notices: [String]
    ) -> String {
        let droppedNotice =
            dropped > 0
            ? [
                "The oldest \(dropped) console messages were dropped because the history of "
                    + "\(EventBuffer.consoleCapacity) was full; the rows below start after them."
            ] : []
        func render(_ page: [ConsoleEntry]) -> String {
            guard !page.isEmpty else { return total == 0 ? "No console messages." : "" }
            let lines = page.map { entry in
                let time = entry.timestamp.formatted(.dateTime.hour().minute().second())
                let origin = entry.source == "javascript" ? " (uncaught)" : ""
                return "[\(Self.clip(entry.level, to: 20))]\(origin) \(time) \(Self.clip(entry.text, to: ToolCatalog.consoleTextWidth))"
            }
            return "Console messages, oldest first:\n" + lines.joined(separator: "\n")
        }
        guard cleared else {
            return ToolStandard.page(
                of: rows, limit: limit, offset: offset, things: "console messages",
                notices: notices + droppedNotice, render: render)
        }
        // The history was forgotten after it was read, so the next page does not exist:
        // the standard's "Pass offset=" sentence would send the caller to nothing.
        return ToolStandard.fitting(limit) { size in
            let page = Array(rows.dropFirst(offset).prefix(size))
            let last = offset + page.count
            var position = Notice.page(offset: offset, count: page.count, total: total, things: "console messages")
            if last < total, !page.isEmpty {
                position =
                    "Showing \(offset + 1)–\(last) of \(total) console messages. The history was cleared, so the rest cannot be read again."
            }
            return ToolStandard.withNotices(
                notices + droppedNotice + [position].compactMap { $0 }, render(page))
        }
    }

    func network(
        _ rows: [NetworkEntry], total: Int, dropped: Int, limit: Int, offset: Int,
        includeHeaders: Bool, notices: [String]
    ) -> String {
        let droppedNotice =
            dropped > 0
            ? [
                "The oldest \(dropped) requests were dropped because the history of "
                    + "\(EventBuffer.networkCapacity) was full; the rows below start after them."
            ] : []
        return ToolStandard.page(
            of: rows, limit: limit, offset: offset, things: "requests",
            notices: notices + droppedNotice
        ) { page in
            guard !page.isEmpty else { return total == 0 ? "No requests." : "" }
            let lines = page.map { entry -> String in
                var line = "\(Self.clip(entry.id, to: ToolCatalog.nameWidth))  \(Self.clip(entry.method, to: 20))  "
                if let failure = entry.failure {
                    line += "FAILED (\(Self.clip(failure, to: ToolCatalog.nameWidth)))"
                } else if let status = entry.status {
                    line += "\(status)"
                } else {
                    line += "pending"
                }
                if let type = entry.mimeType, !type.isEmpty { line += "  \(Self.clip(type, to: ToolCatalog.nameWidth))" }
                if let bytes = entry.bytes { line += "  \(bytes) B" }
                if let ms = entry.durationMilliseconds { line += "  \(ms) ms" }
                line += "  \(entry.url.isEmpty ? "(no URL reported)" : Self.clip(entry.url, to: ToolCatalog.urlWidth))"
                if includeHeaders {
                    line += headerBlock("request", entry.requestHeaders)
                    line += headerBlock("response", entry.responseHeaders)
                }
                return line
            }
            return "Requests, in the order they started:\n" + lines.joined(separator: "\n")
        }
    }

    private func headerBlock(_ label: String, _ headers: [HTTPHeader]) -> String {
        guard !headers.isEmpty else { return "" }
        let shown = headers.prefix(ToolCatalog.headersPerDirection)
        var lines = shown.map {
            "      \(Self.clip($0.name, to: ToolCatalog.nameWidth)): \(Self.clip($0.value, to: ToolCatalog.headerValueWidth))"
        }
        if headers.count > shown.count {
            lines.append(
                "      [Cut at \(shown.count) of \(headers.count) headers; the rest cannot be read again.]")
        }
        return "\n    \(label) headers:\n" + lines.joined(separator: "\n")
    }

    /// One row of `page_storage`. The three kinds are listed in one order, so that a
    /// page can start in one and end in another.
    enum StorageRow {
        case cookie(CookieInfo)
        case local(key: String, value: String)
        case session(key: String, value: String)
    }

    /// Cookies by domain, path and name, then localStorage and sessionStorage by key.
    static func storageRows(_ snapshot: StorageSnapshot) -> [StorageRow] {
        let cookies = snapshot.cookies.sorted {
            ($0.domain, $0.path, $0.name, $0.value) < ($1.domain, $1.path, $1.name, $1.value)
        }
        return cookies.map(StorageRow.cookie)
            + snapshot.local.sorted { $0.key < $1.key }.map { StorageRow.local(key: $0.key, value: $0.value) }
            + snapshot.session.sorted { $0.key < $1.key }.map { StorageRow.session(key: $0.key, value: $0.value) }
    }

    func storage(_ snapshot: StorageSnapshot, limit: Int, offset: Int, notices: [String]) -> String {
        let rows = Self.storageRows(snapshot)
        let sections = [
            "Cookies": snapshot.cookies.count, "localStorage": snapshot.local.count,
            "sessionStorage": snapshot.session.count,
        ]
        return ToolStandard.page(
            of: rows, limit: limit, offset: offset, things: "storage entries", notices: notices
        ) { page in
            guard !rows.isEmpty else { return "No cookies, localStorage or sessionStorage entries." }
            var lines: [String] = []
            var current = ""
            for row in page {
                let (section, line): (String, String)
                switch row {
                case .cookie(let cookie):
                    let flags = (cookie.isHTTPOnly ? ", HttpOnly" : "") + (cookie.isSecure ? ", Secure" : "")
                    section = "Cookies"
                    line =
                        "  \(Self.clip(cookie.name, to: ToolCatalog.nameWidth))=\(Self.clip(cookie.value, to: ToolCatalog.storageValueWidth))"
                        + "  [\(Self.clip(cookie.domain, to: ToolCatalog.nameWidth))\(Self.clip(cookie.path, to: ToolCatalog.nameWidth))\(flags)]"
                case .local(let key, let value):
                    section = "localStorage"
                    line = "  \(Self.clip(key, to: ToolCatalog.nameWidth))=\(Self.clip(value, to: ToolCatalog.storageValueWidth))"
                case .session(let key, let value):
                    section = "sessionStorage"
                    line = "  \(Self.clip(key, to: ToolCatalog.nameWidth))=\(Self.clip(value, to: ToolCatalog.storageValueWidth))"
                }
                if section != current {
                    current = section
                    lines.append("\(section) (\(sections[section] ?? 0)):")
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }
    }
}
