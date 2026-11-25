import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import FirefoxInspectCore

/// In-memory `BrowserInspector`. Every fixture is invented, and every host is
/// `example.com` or a `.invalid` domain, which can never resolve. The suite never starts
/// a browser and never touches a real Firefox profile.
final class FakeInspector: BrowserInspector, @unchecked Sendable {
    var browserStatus = BrowserStatus(
        executablePath: "/fake/firefox", executableExists: true, isRunning: false, version: nil)
    var openedURLs: [String] = []
    var console: [ConsoleEntry] = []
    var droppedConsole = 0
    var network: [NetworkEntry] = []
    var droppedNetwork = 0
    var elementsResult = ElementsResult(matchCount: 1, html: "<h1>Fixture</h1>")
    var bodyText = "body of the request"
    var bodyIsBase64 = false
    var snapshot = StorageSnapshot(
        cookies: [
            CookieInfo(
                name: "session", domain: "example.com", path: "/", value: "fixture",
                isHTTPOnly: true, isSecure: true)
        ], local: ["theme": "dark"], session: [:])
    var screenshotData = FakeInspector.png(width: 64, height: 32)
    var selectors: [String] = []
    var clearedConsole = false
    var failure: InspectError?
    /// Makes `open` slow, for the deadline test.
    var openDelay: Duration?

    func status() async -> BrowserStatus { browserStatus }

    func open(url: String) async throws -> PageInfo {
        if let openDelay { try await Task.sleep(for: openDelay) }
        if let failure { throw failure }
        openedURLs.append(url)
        return PageInfo(url: url, title: "Fixture page")
    }

    func elements(selector: String) async throws -> ElementsResult {
        if let failure { throw failure }
        selectors.append(selector)
        return elementsResult
    }

    func consoleMessages(clear: Bool) async throws -> ConsoleHistory {
        clearedConsole = clear
        return ConsoleHistory(entries: console, dropped: droppedConsole)
    }

    func networkRequests() async throws -> NetworkHistory {
        NetworkHistory(entries: network, dropped: droppedNetwork)
    }

    func responseBody(requestID: String) async throws -> ResponseBody {
        ResponseBody(text: bodyText, isBase64: bodyIsBase64)
    }

    func storage() async throws -> StorageSnapshot { snapshot }

    func screenshot() async throws -> String { screenshotData }

    /// A PNG of `width` × `height` pixels. With `noise` every pixel is pseudo-random, which
    /// no encoder shrinks, so the file is large.
    static func png(width: Int, height: Int, noise: Bool = false) -> String {
        var pixels = [UInt8](repeating: 200, count: width * height * 4)
        if noise {
            var state: UInt64 = 88_172_645_463_325_252
            for index in pixels.indices {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                pixels[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state)
            }
        }
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return (output as Data).base64EncodedString()
    }
}
