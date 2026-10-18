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

    public var message: String {
        switch self {
        case .firefoxNotFound(let path):
            return """
                Firefox was not found at:

                  \(path)

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
            return "Argument '\(name)' is not valid: \(reason)"

        case .unsupportedScheme(let url, let scheme):
            return """
                This server only opens http and https URLs, and '\(url)' is '\(scheme)'.

                'file:' reaches the disk, 'data:' and 'javascript:' carry their payload \
                inline. None of them are opened here.
                """

        case .navigationFailed(let code):
            return """
                Firefox could not load the page (\(code)).

                The usual causes are an unknown host, a refused connection or a certificate \
                error. network_requests lists what was attempted.
                """

        case .pageScriptFailed(let detail):
            return "The page refused the inspection script: \(detail)"

        case .requestNotFound(let id):
            return """
                No request with id '\(id)' has been seen since the last open_url.

                Ids come from network_requests and reset whenever a new page is opened.
                """

        case .bodyUnavailable(let id):
            return """
                Firefox no longer holds the body of request '\(id)'.

                Bodies are only kept for requests made after the browser started, and not \
                for redirects, cached responses or responses over 5 MB.
                """

        case .commandFailed(let code):
            return "Firefox rejected the command (\(code))."
        }
    }
}
