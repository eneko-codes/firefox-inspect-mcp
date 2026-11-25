<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="firefox-inspect-mcp icon">
</p>

# firefox-inspect-mcp

A local [MCP](https://modelcontextprotocol.io) server, written in Swift, that lets Claude look
at a web page the way the browser's inspector does: the DOM, the console, the network
requests, storage and a screenshot. It ships as a Claude extension.

It starts **its own Firefox**: headless, with an empty temporary profile that is deleted when
the server stops. It talks to that browser over
[WebDriver BiDi](https://w3c.github.io/webdriver-bidi/), the standard debugging protocol, on
a random loopback port.

Not affiliated with or endorsed by Mozilla.

## Requirements

- macOS 15 or later, Apple silicon
- Swift 6.0 or later (Xcode 26 ships it)
- Firefox, at `/Applications/Firefox.app` (or pass `--firefox-path`). Developed against 158.

## Tools

| Tool | Inspector panel | What it does |
|---|---|---|
| `firefox_status` | — | Whether Firefox is found and whether the browser it controls is running. Starts nothing. |
| `open_url` | — | Loads an http/https page in the throwaway Firefox, starting it first if needed, and waits. Clears console and network history. |
| `page_elements` | Elements | HTML of the first match for a CSS selector, after scripts ran, read in windows (`character_offset`, `max_characters`). |
| `console_messages` | Console | `console.*` calls and uncaught errors since the page started loading, oldest first, paged (`limit`, `offset`). |
| `network_requests` | Network | Method, URL, status, type, size and duration in the order requests started; headers on request; paged (`limit`, `offset`). |
| `network_response_body` | Network | One response body in windows (`character_offset`, `max_characters`); not redirects, cached responses, or over 5 MB. |
| `page_storage` | Storage | Cookies (HttpOnly included), `localStorage` and `sessionStorage` of the throwaway browser, paged (`limit`, `offset`). |
| `page_screenshot` | — | One image of the loaded page's viewport, scaled down to the image limits when it is larger. |

There is deliberately **no tool that runs caller-supplied JavaScript**. The scripts that read
the page are fixed, and take the selector as an argument, never as code.

## Frameworks and APIs

| Used | For | Reference |
|---|---|---|
| WebDriver BiDi, over one WebSocket (`URLSessionWebSocketTask`) | Everything the tools read from the page | [WebDriver BiDi](https://w3c.github.io/webdriver-bidi/), [URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask) |
| `Foundation.Process` | Starting and stopping the headless Firefox | [Process](https://developer.apple.com/documentation/foundation/process) |
| `MCPServer.swift` and `Value.swift`, over Foundation | The stdio server and the tool protocol (JSON-RPC over stdio) | [Model Context Protocol](https://modelcontextprotocol.io) |

There is **no third-party dependency**: `Package.swift` lists none.

## What a result holds

No result holds everything. A notice in its first lines says what it leaves out and the
exact argument that returns the rest (`offset`, or `character_offset` for a window on a long
text), in the same words in every one of the owner's servers. Whatever a tool pages or
windows, it states the order. A long field inside a row (a console message, a URL, a header
or a stored value) is clipped, says so, and the rest cannot be read again. The console and
network keep a bounded history and say when older entries were dropped. A call that does not
finish in time is answered with an error saying so. The sizes are constants in
`Sources/FirefoxInspectCore/ToolCatalog.swift`; the tool descriptions quote them, and
`BoundsTests` holds every bound and notice to them.

## The rules worth knowing before you use it

**It is not your browser.** It cannot see your open tabs, logins, cookies or history, and a
page that needs a login shows its logged-out state. That separation is the point: nothing
here can read your real session.

**No telemetry, and no network of its own** beyond the pages you ask it to open. Firefox is
launched with its telemetry, update and safe-browsing traffic switched off in the profile
(`Sources/FirefoxInspectCore/FirefoxProcess.swift`).

**Everything a page returns is untrusted.** The server's instructions tell the model so, but
treat page content as input from the internet, not from you.

**Logs are fixed events only** — start, browser start time, tool name, error kind and
duration — written to stderr. A URL, selector, header, cookie or console line is never
logged. stdout is the JSON-RPC stream and nothing else writes to it.

## Install

### 1. Build the bundle

```bash
./scripts/pack.sh
```

That builds an arm64-only release binary, signs it, checks the bundle, and writes
`dist/firefox-inspect-mcp.mcpb`. It signs ad hoc unless `MCPB_SIGN_IDENTITY` is set; see
[Signing](#signing).

### 2. Install it

Open `dist/firefox-inspect-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and
reopen it** — installing does not replace a server process that is already running.

### 3. Point it at Firefox, if it is not in the usual place

The extension has one setting: the full path to the Firefox executable. Leave it empty to
use `/Applications/Firefox.app`.

### Signing

Nothing this server does is behind a macOS privacy permission, so an ad-hoc signature is
enough; it only replaces the linker's signature with a proper one. There is nothing to
grant in System Settings.

To sign it like the other servers on the Mac, pass a certificate's hash:

```bash
security find-identity -v -p codesigning   # copy the 40-character hash of an Apple Development or Developer ID Application identity
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

Pass the hash, not the certificate's name: `pack.sh` prints the identity it signs with,
and the name is yours. Never publish a bundle signed with a personal certificate.

## Tool switches

Every tool can be turned on or off individually in Claude Desktop, because the manifest
declares all eight. **Reinstalling may reset the switches**; check them after every install.

## Manual registration instead

```bash
swift build -c release
```

```json
{
  "mcpServers": {
    "firefox-inspect": {
      "command": "/path/to/firefox-inspect-mcp/.build/release/firefox-inspect-mcp"
    }
  }
}
```

Optional: `--firefox-path /path/to/firefox` to use a different Firefox build. You lose the
per-tool switches. Do not register it both ways at once.

## Known limits

- **Not available:** Sources/debugger (breakpoints, source maps), timelines, memory, graphics
  and layers. WebDriver BiDi does not expose them, and this server does not pretend
  otherwise.
- **Response bodies:** not for redirects, cached responses, or anything over 5 MB; binary
  bodies come back as base64.
- **History belongs to the loaded page.** Opening a new page clears the console and network history.

## Development

```bash
swift build
swift test
```

The suite runs against fakes (a scripted BiDi transport and an in-memory inspector) with
invented data and `example.com` hosts. It never starts Firefox.

`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift`
and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers
(the test files differ only in their `@testable import`). `ToolStandard.swift` holds the
limits, the fixed wording of every notice and the guard every result passes through.
`Deadline.swift` is a copy too, until it moves into the shared file. A change to one is made to every copy in the same piece of work; never
let a copy drift.

## Licence

MIT.
