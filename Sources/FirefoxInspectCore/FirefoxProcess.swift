import Foundation

/// A Firefox started by this server, in its own throwaway profile.
///
/// The profile lives in a fresh temporary directory and is deleted on `stop()`. It is
/// never the person's real profile: no logins, no history, no extensions. That is what
/// makes it safe to hand the page to a model, and the reason this server cannot inspect
/// the tabs the person is already using.
final class FirefoxProcess: @unchecked Sendable {
    /// Telemetry, crash and update traffic off, and nothing restored on start.
    /// Firefox reads this once at startup from `user.js`.
    static let profilePreferences = """
        user_pref("datareporting.policy.dataSubmissionEnabled", false);
        user_pref("datareporting.healthreport.uploadEnabled", false);
        user_pref("toolkit.telemetry.enabled", false);
        user_pref("toolkit.telemetry.unified", false);
        user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
        user_pref("app.shield.optoutstudies.enabled", false);
        user_pref("app.normandy.enabled", false);
        user_pref("browser.crashReports.unsubmittedCheck.enabled", false);
        user_pref("breakpad.reportURL", "");
        user_pref("app.update.auto", false);
        user_pref("app.update.enabled", false);
        user_pref("browser.shell.checkDefaultBrowser", false);
        user_pref("browser.startup.page", 0);
        user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
        user_pref("browser.newtabpage.activity-stream.telemetry", false);
        user_pref("network.captive-portal-service.enabled", false);
        user_pref("network.connectivity-service.enabled", false);
        user_pref("browser.safebrowsing.malware.enabled", false);
        user_pref("browser.safebrowsing.phishing.enabled", false);
        user_pref("extensions.update.enabled", false);
        user_pref("extensions.getAddons.cache.enabled", false);
        """

    private let process = Process()
    private let profileDirectory: URL
    private let lock = NSLock()
    private var stopped = false

    /// Starts Firefox and returns once it has announced its BiDi endpoint.
    ///
    /// Port 0 asks Firefox for any free port, so two instances never collide and the
    /// endpoint is not a well-known number another local process could guess.
    static func launch(executable: String, timeout: Duration = .seconds(30)) async throws -> (
        process: FirefoxProcess, endpoint: URL
    ) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw InspectError.firefoxNotFound(path: executable)
        }
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("firefox-inspect-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profile, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(profilePreferences.utf8).write(to: profile.appendingPathComponent("user.js"))

        let instance = FirefoxProcess(profileDirectory: profile)
        do {
            let endpoint = try await instance.start(executable: executable, timeout: timeout)
            return (instance, endpoint)
        } catch {
            instance.stop()
            throw error
        }
    }

    private init(profileDirectory: URL) {
        self.profileDirectory = profileDirectory
    }

    private func start(executable: String, timeout: Duration) async throws -> URL {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "--headless", "--no-remote", "--profile", profileDirectory.path,
            "--remote-debugging-port", "0", "about:blank",
        ]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let announcement = Announcement()
        // Keep reading after the endpoint is found: a full pipe would block Firefox.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            announcement.feed(String(decoding: data, as: UTF8.self))
        }

        try process.run()

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let endpoint = announcement.endpoint { return endpoint }
            if !process.isRunning { throw InspectError.firefoxExited }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw InspectError.firefoxDidNotStart
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if process.isRunning {
            process.terminate()
            // Firefox flushes the profile on SIGTERM; give it a moment before removing it.
            let end = Date().addingTimeInterval(3)
            while process.isRunning && Date() < end { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: profileDirectory)
    }

    /// Finds `ws://127.0.0.1:PORT` in Firefox's startup output.
    final class Announcement: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var found: URL?

        var endpoint: URL? {
            lock.lock()
            defer { lock.unlock() }
            return found
        }

        func feed(_ text: String) {
            lock.lock()
            defer { lock.unlock() }
            guard found == nil else { return }
            buffer += text
            found = Self.endpoint(in: buffer)
        }

        static func endpoint(in text: String) -> URL? {
            guard let range = text.range(of: "WebDriver BiDi listening on ") else { return nil }
            let rest = text[range.upperBound...]
            let candidate = rest.prefix { !$0.isWhitespace }
            guard let url = URL(string: String(candidate)), url.scheme == "ws",
                url.host == "127.0.0.1" || url.host == "localhost", url.port != nil
            else { return nil }
            return url
        }
    }
}
