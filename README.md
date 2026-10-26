# firefox-inspect-mcp

A small local [MCP](https://modelcontextprotocol.io) server that lets a model look at a web
page the way the browser's inspector does: the DOM, the console, the network requests,
storage and a screenshot. Swift 6, stdio transport, one dependency (the MCP Swift SDK).

It is not affiliated with or endorsed by Mozilla.

## What it is, and is not

It starts **its own Firefox**: headless, with an empty temporary profile that is deleted
when the server stops. It talks to that browser over [WebDriver BiDi](https://w3c.github.io/webdriver-bidi/),
the standard debugging protocol, on a random loopback port.

It is **not** your everyday browser. It cannot see your open tabs, logins, cookies or
history, and a page that needs a login shows its logged-out state. That separation is the
point: nothing here can read your real session.

No telemetry, no network access of its own beyond the pages you ask it to open. Firefox
is launched with its telemetry, update and safe-browsing traffic switched off in the
profile (`Sources/FirefoxInspectCore/FirefoxProcess.swift`).

## Tools

| Tool | Inspector panel | Notes |
|---|---|---|
| `open_url` | — | Loads an http/https page and waits. Clears console and network history. |
| `page_elements` | Elements | HTML of the first match for a CSS selector, after scripts ran. |
| `console_messages` | Console | `console.*` calls and uncaught errors since the page started loading. |
| `network_requests` | Network | Method, URL, status, type, size, duration; headers on request. |
| `network_response_body` | Network | One response body (not redirects, cached responses, or over 5 MB). |
| `page_storage` | Storage | Cookies (HttpOnly included), `localStorage`, `sessionStorage`. |
| `page_screenshot` | — | PNG of the viewport. |
| `firefox_status` | — | Whether Firefox is found and the browser is running. |

There is deliberately **no tool that runs caller-supplied JavaScript**. The scripts
that read the page are fixed, and take the selector as an argument, never as code.

### Not available

Sources/debugger (breakpoints, source maps), timelines, memory, graphics and layers.
WebDriver BiDi does not expose them, and this server does not pretend otherwise.

## Requirements

- macOS 15 or later, Apple silicon.
- Firefox, at `/Applications/Firefox.app` (or pass `--firefox-path`). Developed against 158.

## Build and run

```bash
swift build -c release
swift test
```

The binary is `.build/release/firefox-inspect-mcp`. Point an MCP client at it:

```json
{
  "mcpServers": {
    "firefox-inspect": {
      "command": "/path/to/firefox-inspect-mcp/.build/release/firefox-inspect-mcp"
    }
  }
}
```

Optional: `--firefox-path /path/to/firefox` to use a different Firefox build.

### As a Claude extension

```bash
./scripts/pack.sh
```

This builds an arm64-only release binary and packs `dist/firefox-inspect-mcp.mcpb`; open
the file with Claude to install it. The extension's one setting is an optional Firefox path.

## Privacy and logging

Logs go to stderr as fixed events only: start, browser start time, tool name, error kind
and duration. A URL, selector, header, cookie or console line is never logged. stdout is
the JSON-RPC stream and is never written to by anything else.

Everything a page returns is untrusted. The server's instructions tell the model so, but
treat page content as input from the internet, not from you.

## Tests

The suite runs against fakes (a scripted BiDi transport and an in-memory inspector) with
invented data and `example.com` hosts. It never starts Firefox.

## License

MIT.
