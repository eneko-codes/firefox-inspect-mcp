import Dispatch
import FirefoxInspectCore
import Foundation

// Launcher only. Everything testable lives in FirefoxInspectCore.
let configuration = Configuration.parse(Array(CommandLine.arguments.dropFirst()))
let inspector = FirefoxInspector(executable: configuration.firefoxPath)

// The browser is a child process with a profile on disk. A terminating signal must stop
// it first, or Firefox keeps running with nothing left to talk to it.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    source.setEventHandler {
        Task {
            await inspector.shutdown()
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

do {
    try await InspectMCPServer.run(inspector: inspector)
    await inspector.shutdown()
} catch {
    // Exiting 0 here would be indistinguishable from a clean shutdown.
    Diagnostics.fatal(error)
    await inspector.shutdown()
    exit(1)
}
