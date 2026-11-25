import Foundation

public enum InspectError: Error, Equatable {
    case firefoxNotFound(path: String)
    case firefoxExited
    case firefoxDidNotStart
    case browserLost
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case unsupportedScheme(url: String, scheme: String)
    case navigationFailed(code: String)
    case pageScriptFailed(String)
    case requestNotFound(id: String)
    case bodyUnavailable(id: String)
    case commandFailed(code: String)
    case commandTimedOut(seconds: Int)
    case timedOut(seconds: Int, tool: String)
    case elementTooLarge(size: Int)
    case screenshotUnreadable
    case screenshotTooLarge

    public var message: String {
        switch self {
        case .firefoxNotFound(let path):
            return """
                Firefox was not found at:

                  \(ToolStandard.echo(path))

                Install Firefox, or start this server with --firefox-path pointing at the \
                executable inside the app bundle (Firefox.app/Contents/MacOS/firefox).
                """

        case .firefoxExited:
            return """
                Firefox exited while starting.

                It was launched headless with a temporary profile and no other options. \
                Running that command by hand in a terminal shows why.
                """

        case .firefoxDidNotStart:
            return """
                Firefox did not announce its debugging endpoint within 30 seconds.

                Nothing was left running; the next call starts a fresh browser.
                """

        case .browserLost:
            return """
                The browser this server started has gone away.

                Nothing was left running; the next call starts a fresh one. Console and \
                network history from the previous browser is gone.
                """

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(ToolStandard.echo(name))' is not valid: \(reason)"

        case .unsupportedScheme(let url, let scheme):
            return """
                This server only opens http and https URLs, and '\(ToolStandard.echo(url))' is '\(ToolStandard.echo(scheme))'.

                'file:' reaches the disk, 'data:' and 'javascript:' carry their payload \
                inline. None of them are opened here.
                """

        case .navigationFailed(let code):
            return """
                Firefox could not load the page (\(ToolStandard.echo(code))).

                The usual causes are an unknown host, a refused connection or a certificate \
                error. network_requests lists what was attempted.
                """

        case .pageScriptFailed(let detail):
            return "The page refused the inspection script: \(ToolStandard.echo(detail))"

        case .requestNotFound(let id):
            return """
                No request with id '\(ToolStandard.echo(id))' has been seen since the last open_url.

                Ids come from network_requests and reset whenever a new page is opened.
                """

        case .bodyUnavailable(let id):
            return """
                Firefox no longer holds the body of request '\(ToolStandard.echo(id))'.

                Bodies are only kept for requests made after the browser started, and not \
                for redirects, cached responses or responses over 5 MB.
                """

        case .commandFailed(let code):
            return "Firefox rejected the command (\(ToolStandard.echo(code)))."

        case .commandTimedOut(let seconds):
            return """
                Firefox did not answer a command within \(seconds) seconds.

                A page that is busy or very large can cause this. Ask for less (a narrower \
                selector, a smaller limit or max_characters), or call open_url again to \
                start from a fresh page.
                """

        case .timedOut(let seconds, let tool):
            let advice =
                tool == ToolCatalog.openURLName
                ? "The page may still be loading, or may have loaded since: page_elements shows what the browser holds now."
                : "Ask for less: a narrower selector, a smaller limit or a smaller max_characters."
            return """
                The call did not finish within \(seconds) seconds and was abandoned. The \
                browser may still be working on it.

                \(advice)
                """

        case .elementTooLarge(let size):
            return """
                The first matching element holds \(size) characters, more than the \
                \(ToolCatalog.largestElement) this server reads.

                Pass a selector that matches a smaller element.
                """

        case .screenshotUnreadable:
            return "Firefox returned a screenshot this server could not read. Try page_screenshot again."

        case .screenshotTooLarge:
            return """
                The screenshot could not be made small enough: it must be at most \
                \(ToolCatalog.largestScreenshotSide) pixels on its long side and \
                \(ToolCatalog.largestScreenshotBytes) bytes.

                Call open_url for a page with a plainer viewport and try again.
                """

        }
    }
}
