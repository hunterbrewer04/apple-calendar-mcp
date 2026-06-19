# apple-calendar-mcp

> A fast, **read-only** Apple Calendar tool for macOS: one native Swift binary that is both an
> `ical` terminal CLI and an MCP server (stdio + token-gated HTTP). It reads the calendar
> database directly through EventKit (~100ms per query) — Calendar.app never has to be running.

## Install

```bash
brew install hunterbrewer04/tap/apple-calendar
```

This builds from source, code-signs the binary with a stable identity (so the macOS Calendar
permission survives upgrades), and installs it as `ical`. **macOS 14+** required. On the first
calendar read, macOS shows a one-time **"Allow Full Access"** dialog — click it.

## Quickstart (CLI)

```
$ ical today
  Jun 19  9:00 AM – 9:15 AM   Standup
                              📅 Work
  Jun 19  12:30 PM – 1:30 PM  Lunch with Alex
                              📍 Cafe Roma
                              📅 Personal
  Jun 19  all day             Q3 Planning Offsite
                              📅 Work
```

### Subcommands

| Command | Shows |
|---|---|
| `ical today` | today (default when no subcommand) |
| `ical tomorrow` | tomorrow |
| `ical week` | next 7 days |
| `ical month` | next 30 days |
| `ical next N` | next N days |
| `ical calendars` | list calendar names |
| `ical cal "NAME" [DAYS]` | one calendar (default 7 days) |
| `ical detail [period]` | any period, with notes + URLs |
| `ical debug [period]` | raw pipe-delimited output |

Add `-x` (or `--detail`) to any command to include notes and URLs.

## MCP server

The same binary speaks the Model Context Protocol, so Claude (or any MCP client) can read your
calendar through the same EventKit core.

### stdio (local client)

```json
{
  "mcpServers": {
    "apple-calendar": { "type": "stdio", "command": "ical", "args": ["mcp"] }
  }
}
```

### HTTP (remote client over a private network)

Run the server — a bearer token is **required** (see [Security](#security)):

```bash
export CALENDAR_MCP_TOKEN="$(openssl rand -hex 16)"
ical mcp --http            # binds 127.0.0.1:3456 by default
```

Then point a remote client at it (a ready-to-edit copy is in
[`examples/mcp-config.json`](examples/mcp-config.json)):

```json
{
  "mcpServers": {
    "apple-calendar": {
      "type": "http",
      "url": "http://YOUR-HOST:3456/mcp",
      "headers": { "Authorization": "Bearer YOUR-TOKEN" }
    }
  }
}
```

### Run it as a background service

`brew services` launches a launchd agent. Because the server is fail-closed, the token has to
reach the service environment — inject it with `launchctl setenv` before starting:

```bash
launchctl setenv CALENDAR_MCP_TOKEN "$(openssl rand -hex 16)"
brew services start apple-calendar
```

To expose it on a private-network address (e.g. a Tailscale IP) instead of loopback:

```bash
launchctl setenv CALENDAR_MCP_HOST "$(tailscale ip -4)"
brew services restart apple-calendar
```

### Tools

`list_calendars`, `get_today`, `get_tomorrow`, `get_week`, `get_month`,
`get_next_days(days)`, `get_calendar_events(calendar_name, days)`. Each accepts an optional
`details: bool`. Output is the same pretty text the CLI prints.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `CALENDAR_MCP_TOKEN` | — | Bearer token; required for HTTP mode |
| `CALENDAR_MCP_HOST` | `127.0.0.1` | HTTP bind address |
| `CALENDAR_MCP_PORT` | `3456` | HTTP port |

`--host`, `--port`, and `--no-auth` may also be passed on the command line.

## Security

- **Read-only.** The tool only queries events — it never creates, edits, or deletes anything.
- **Bearer token, fail-closed.** HTTP mode requires `CALENDAR_MCP_TOKEN` and refuses to start
  without one. Tokens are compared in constant time. Passing `--no-auth` overrides this and
  prints a loud warning — only do that on a trusted, isolated interface.
- **macOS-only, gated by TCC.** Calendar access is granted per code identity by macOS. The
  binary is code-signed with a stable identifier (`com.apple-calendar-mcp.cli`) so the grant
  persists across upgrades.
- **No transport encryption built in.** HTTP mode speaks plain HTTP. Run it only on a
  private/trusted network (loopback, a VPN, or a tailnet) — never expose port 3456 to the
  public internet.

### Hardening (optional)

- **Tailscale ACLs.** If you serve over a tailnet, restrict who can reach the port in your
  tailnet ACL policy — e.g. allow only your own devices to reach `*:3456`.
- **WireGuard `AllowedIPs`.** On a plain WireGuard VPN, scope the peer's `AllowedIPs` to just
  the host/port you need, and bind `CALENDAR_MCP_HOST` to the VPN interface address rather than
  a wildcard.

## Build from source

```bash
swift build -c release
codesign -s - --identifier com.apple-calendar-mcp.cli --force .build/release/apple-calendar
```

The codesign step is required after **every** rebuild — the stable identity is what keeps the
macOS Calendar permission valid across recompiles. (Homebrew runs this step for you.)

> A full Swift toolchain runs the test suite. A Command Line Tools-only install can `swift build`
> and run the binary, but cannot `swift test` (no XCTest); CI runs the tests on a macOS runner.

## Architecture

```
ical <subcommand>   → CLI ───────┐
ical mcp            → stdio MCP ──┼─→ CalendarCore (EventKit) → macOS calendar DB (~100ms)
ical mcp --http     → HTTP MCP ───┘    (bearer auth, fail-closed)
```

A shared EventKit reader feeds both front-ends. The MCP layer uses the official
[Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk) for the protocol + stdio
transport, and a [Hummingbird](https://github.com/hummingbird-project/hummingbird)-backed
transport for token-gated Streamable HTTP.

## License

MIT — see [LICENSE](LICENSE).
