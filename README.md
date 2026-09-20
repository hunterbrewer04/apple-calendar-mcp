# apple-calendar-mcp

[![CI](https://github.com/hunterbrewer04/apple-calendar-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/hunterbrewer04/apple-calendar-mcp/actions/workflows/ci.yml)
[![Version](https://img.shields.io/github/v/tag/hunterbrewer04/apple-calendar-mcp?label=version&sort=semver)](https://github.com/hunterbrewer04/apple-calendar-mcp/tags)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](#requirements)
[![License: MIT](https://img.shields.io/github/license/hunterbrewer04/apple-calendar-mcp)](LICENSE)

A fast, native Apple Calendar tool for macOS. One small binary is both an `ical` terminal
command and an MCP server, so any MCP-compatible AI app can read and change your calendar,
on this Mac or from another machine on your private network.

It talks to the macOS calendar database directly through EventKit (about 100 ms per query).
Calendar.app never has to be open and nothing leaves your machine.

- 🗓️ Instant queries: today, this week, the next N days, one calendar by name.
- ✏️ Create, update, and delete events from the CLI or any MCP client.
- 🔌 Two ways to connect: a local `stdio` server, or an HTTP server other machines can reach.
- 🔐 Per-client tokens: each machine gets its own revocable credential; the server refuses to start with none.
- 🍺 One-command install: Homebrew builds and code-signs it; one more command runs it in the background.

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

## Contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [CLI reference](#cli-reference)
- [MCP server](#mcp-server)
  - [Tools](#tools)
  - [Local (stdio)](#local-stdio)
  - [Networked (HTTP)](#networked-http)
  - [Managing the networked server](#managing-the-networked-server)
- [Troubleshooting](#troubleshooting)
- [Configuration reference](#configuration-reference)
- [Security model](#security-model)
- [Uninstall](#uninstall)
- [Build from source](#build-from-source)
- [Claude Code skill](#claude-code-skill)
- [How it works](#how-it-works)
- [License](#license)

## Quick start

### 1. Install

```bash
brew install hunterbrewer04/tap/apple-calendar
```

Homebrew builds the binary from source (it compiles Swift, so allow a few minutes), installs it as `ical`,
and code-signs it with a stable identity so the macOS Calendar permission keeps working across
upgrades.

### 2. Grant Calendar access

```bash
ical today
```

The first read triggers a one-time macOS dialog. Click **Allow Full Access**. Do this from
Terminal before anything else: a background server may not be able to show you the dialog,
and every MCP client depends on this grant.

### 3. Connect an AI app

Pick the row that matches where the AI app runs.

| The app runs on... | Do this |
|---|---|
| This Mac (Claude Code, Claude Desktop, Cursor, ...) | Add the [local stdio config](#local-stdio). No token, no network. |
| Another machine (a server, laptop, or remote Claude Code) | `ical serve setup --tailscale`, then `ical serve connect <ssh-host>`. See [Networked (HTTP)](#networked-http). |

Claude Code on this Mac, in one line:

```bash
claude mcp add --scope user apple-calendar -- ical mcp
```

That's it. Ask your assistant what's on your calendar.

## Requirements

- macOS 14 (Sonoma) or newer. The tool uses EventKit's full-access API.
- Homebrew and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not
  required to install or run; it is only needed to run the test suite.

## CLI reference

### Reading

| Command | Shows |
|---|---|
| `ical` or `ical today` | today (the default) |
| `ical tomorrow` | tomorrow |
| `ical week` | the next 7 days |
| `ical month` | the next 30 days |
| `ical next 14` | the next N days |
| `ical cal "Work" 14` | one calendar by name, optional day count (default 7) |
| `ical calendars` | the names of all your calendars |
| `ical detail week` | `today`, `tomorrow`, `week`, `month`, or `next N`, with notes, URLs, and event ids |
| `ical debug today` | same periods, raw pipe-delimited output for scripts |

Add `-x` (or `--detail`) to any read command to include notes, URLs, and the event id that
`edit` and `rm` need (for a single calendar: `ical cal "Work" 14 -x`). `ical detail <period>` is
the same thing with `-x` implied.

Recurring events are expanded into individual occurrences. A multi-day event that started
earlier still shows up (with its original start date) for as long as it overlaps the window.

### Writing

```bash
# a timed event
ical add --title "Standup" --start 2026-07-01T09:00 --end 2026-07-01T09:15 --cal "Work"

# an all-day event
ical add --title "Offsite" --start 2026-07-01 --all-day --cal "Work"

# find an event's id, then edit or remove it
ical detail today            # read the 🆔 line
ical edit <id> --title "Standup (moved)" --start 2026-07-01T09:30 --end 2026-07-01T09:45
ical rm <id>
```

| Command | Does |
|---|---|
| `ical add --title T --start ISO [--end ISO] [--all-day] [--cal NAME] [--location L] [--notes N] [--url U]` | create an event |
| `ical edit ID [--title T] [--start ISO] [--end ISO] [--all-day] [--cal NAME] [--location L] [--notes N] [--url U]` | change only the fields you pass |
| `ical rm ID` | delete an event |

- Dates are ISO-8601: `2026-07-01T14:30` or `2026-07-01T14:30:00`, with an optional `Z` or
  offset. Without an offset they're read in the Mac's local time zone.
- All-day events take a plain date (`2026-07-01`). Timed events require `--end`.
- With no `--cal`, new events go to your default calendar.
- Aliases: `calendar` for `cal`, `delete` for `rm`, `thisweek` for `week`, `details` or `notes`
  for `detail`, `--calendar` for `--cal`, `--loc` for `--location`, `--allday` for `--all-day`.
- Every error exits non-zero with the fix on stderr.

## MCP server

The same binary speaks the [Model Context Protocol](https://modelcontextprotocol.io), so an AI
assistant can call your calendar as a tool.

### Tools

| Tool | Arguments | What it does |
|---|---|---|
| `list_calendars` | | names of all calendars |
| `get_today`, `get_tomorrow` | `details?` | a single day |
| `get_week`, `get_month` | `details?` | the next 7 / 30 days |
| `get_next_days` | `days`, `details?` | the next N days |
| `get_calendar_events` | `calendar_name`, `days?` (7), `details?` | one calendar by name |
| `create_event` | `title`, `start`, `end?`, `all_day?`, `calendar_name?`, `location?`, `notes?`, `url?` | create an event |
| `update_event` | `event_id`, plus any of the fields above | change only the fields you pass |
| `delete_event` | `event_id` | delete an event |

`details: true` on any read tool adds notes, URLs, and each event's `id`, which `update_event`
and `delete_event` need. `create_event` requires `end` unless `all_day` is true. Dates follow the
same ISO-8601 rules as the CLI.

### Local (stdio)

For an app on the same Mac. The app launches `ical mcp` itself and talks over stdin/stdout:
no network, no token.

Claude Code:

```bash
claude mcp add --scope user apple-calendar -- ical mcp
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`) or any
other client that takes a JSON config:

```json
{
  "mcpServers": {
    "apple-calendar": { "command": "/opt/homebrew/bin/ical", "args": ["mcp"] }
  }
}
```

GUI apps don't see your shell's `PATH`, so use the absolute path from `which ical`
(`/opt/homebrew/bin/ical` on Apple Silicon, `/usr/local/bin/ical` on Intel).

### Networked (HTTP)

For an app on another machine. The Mac runs a small HTTP server in the background; other
machines on your private network call it with a bearer token.

> The server speaks plain HTTP with no encryption and grants read and write access to your
> whole calendar. Only run it on a private network (a VPN like Tailscale, or loopback). Never
> expose port 3456 to the internet.

#### Step 1: grant Calendar access on the Mac

If you skipped it above, run `ical today` in Terminal and click Allow Full Access. The
background server inherits this grant; it may not be able to prompt for it on its own.

#### Step 2: put both machines on a private network

Tailscale is the easiest: install it on the Mac and the client, sign both into the same
tailnet, and you're done. `ical serve setup --tailscale` reads the Mac's tailnet IP for you.

<details>
<summary>Optional: restrict the port with a tailnet ACL</summary>

In the Tailscale admin console policy file, allow only your own devices to reach the port:

```jsonc
{
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["YOUR-MAC:3456"] }
  ]
}
```

</details>

<details>
<summary>WireGuard or another private network</summary>

Bind to the Mac's address on that network with `--host`:

```bash
ical serve setup --host 10.0.0.1
```

On each WireGuard peer, scope `AllowedIPs` so only that route goes through the tunnel:

```ini
[Peer]
# ...the Mac's public key + endpoint...
AllowedIPs = 10.0.0.1/32
```

</details>

#### Step 3: start the server

```bash
ical serve setup --tailscale        # or: --host <private-ip>
```

One command does everything:

- Generates a token at `~/.config/apple-calendar/token` (mode 600). An existing token is
  reused; `--force` rotates it.
- Writes a user LaunchAgent (`~/Library/LaunchAgents/com.apple-calendar-mcp.plist`) that
  points at Homebrew's stable `opt` path, so it survives reboots and `brew upgrade`.
- Starts it, probes it, and prints the client config plus a ready-made `claude mcp add` line.

Flags: `--tailscale`, `--host <ip>`, or `--local` (loopback, the default); `--port <n>`
(default 3456); `--force`. Safe to re-run at any time.

#### Step 4: connect a client

Three ways, depending on what's on the other machine.

**Claude Code, with key-based ssh to that machine.** Run this on the Mac:

```bash
ical serve connect my-server         # any ssh host or ~/.ssh/config alias
```

It mints a token scoped to that host (reused on repeat runs), registers the server in that
machine's Claude Code (user scope) over ssh, and probes the server from that side to confirm
it's reachable and auth is enforced. The token only ever travels over ssh. Requires `claude`
on the remote's login-shell `PATH`.

**Claude Code, no ssh.** Print the one-liner and paste it there yourself:

```bash
ical serve connect my-server --print
```

**Any other MCP client.** Mint that client a token, then paste the config it prints:

```bash
ical serve token add my-laptop
```

```json
{
  "mcpServers": {
    "apple-calendar": {
      "type": "http",
      "url": "http://YOUR-MAC-IP:3456/mcp",
      "headers": { "Authorization": "Bearer YOUR-TOKEN" }
    }
  }
}
```

An editable copy is in [`examples/mcp-config.json`](examples/mcp-config.json). Client names may use
letters, digits, `.`, `_`, and `-`, and must start with a letter or digit; `default` is reserved.

Each machine gets its own credential, so you can cut one off without touching the rest:
`ical serve token revoke my-laptop` takes effect on the running server within about 5 seconds.

#### Step 5: verify from the client

```bash
# no token → 401 means the server is up and locked
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://YOUR-MAC-IP:3456/mcp \
  -H 'Accept: application/json, text/event-stream' -d '{}'

# with token → an initialize response
curl -s -X POST http://YOUR-MAC-IP:3456/mcp \
  -H 'Authorization: Bearer YOUR-TOKEN' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
```

### Managing the networked server

| Command | Does |
|---|---|
| `ical serve status` | LaunchAgent state, liveness (`401` = up and locked), known clients, and the client config |
| `ical serve token list` | every client with a `sha256:` fingerprint (never prints raw tokens) |
| `ical serve token show <client>` | print one client's token, no trailing newline (`\| pbcopy` friendly) |
| `ical serve token add <client> [--force]` | mint a token for a named client; `--force` rotates an existing one |
| `ical serve token revoke <client>` | delete a client's token; the server rejects it within ~5 s, no restart |
| `ical serve token` | print the default token written by `setup` |
| `ical serve setup ... --force` | rotate the default token and restart |
| `ical serve uninstall [--purge]` | stop and remove the server; `--purge` also deletes every token |

Logs go to `~/Library/Logs/apple-calendar.log`. Each session is attributed to the client
whose token opened it (`session <id> client=<name>`).

The server handles many concurrent clients and reconnects; each MCP session is isolated.

<details>
<summary>Run the HTTP server by hand instead</summary>

```bash
export CALENDAR_MCP_TOKEN="$(openssl rand -hex 16)"
ical mcp --http                                   # listens on 127.0.0.1:3456
ical mcp --http --host 100.x.y.z --port 3456      # bind elsewhere
```

Without a token from any source the server refuses to start. There is deliberately no
`brew services` integration: a brew-managed plist is regenerated on upgrade and would lose any
injected environment, leaving the fail-closed server down. `ical serve setup` is the supported
persistent path.

</details>

## Troubleshooting

### Calendar permission

| Symptom | Fix |
|---|---|
| `Calendar access denied` | System Settings → Privacy & Security → Calendars, enable access for the app that ran the command (Terminal, iTerm, Claude, ...), then retry. |
| `permission dialog was never answered` / access request timed out | A dialog is waiting on screen, or the call came from a background process that can't show one. Run `ical today` in Terminal on the Mac and click Allow Full Access. |
| A remote client gets `Calendar access denied` | On the Mac: run `ical today` in Terminal and approve if asked, restart the server with `launchctl kickstart -k gui/$(id -u)/com.apple-calendar-mcp`, then retry. If it still fails, check System Settings → Privacy & Security → Calendars. |
| Permission lost after rebuilding from source | You skipped the `codesign` step. See [Build from source](#build-from-source). |

### Networked server

| Symptom | Fix |
|---|---|
| `Could not get a Tailscale IP` | Tailscale isn't installed or up on the Mac. Run `tailscale up`, or pass `--host <ip>` instead. |
| `serve setup` says the server did NOT come up | Read `~/Library/Logs/apple-calendar.log`. Usually another agent owns the port (setup names it and prints the command to stop it), or the VPN IP wasn't ready yet. Fix that and re-run setup. |
| `ical serve status` shows down after `brew upgrade` | The upgrade removed the old binary under the running server and it doesn't always come back on its own. `launchctl kickstart -k gui/$(id -u)/com.apple-calendar-mcp`, or re-run `ical serve setup --tailscale`. |
| `The server is bound to loopback` | Setup ran without `--tailscale` or `--host`. Re-run with one. |
| `Refusing to start: no auth token found` | You ran `ical mcp --http` by hand with no token. Run `ical serve setup`, or set `CALENDAR_MCP_TOKEN`. |

### Connecting clients

| Symptom | Fix |
|---|---|
| Client gets `401 Unauthorized` | Token mismatch. Re-copy it with `ical serve token show <client> \| pbcopy`, check `ical serve token list`, and confirm the header is exactly `Authorization: Bearer <token>`. |
| `serve connect`: `claude CLI was not found on <host>` (exit 40) | Install Claude Code on that machine, or make sure `claude` is on its login-shell `PATH`. |
| `serve connect`: `could not reach the server over the tailnet` (exit 41) | That machine can't open `http://<mac-ip>:3456`, or has no `curl`. Check `tailscale status` on both ends and any firewall. |
| `serve connect`: `ssh to <host> failed` (exit 255) | Key-based ssh isn't set up. Make `ssh <host>` work non-interactively, or use `--print` and paste the command yourself. |
| Claude Desktop can't launch the server | GUI apps don't see your shell `PATH`. Use the absolute path from `which ical` in `"command"`. |
| `Calendar 'X' not found` | Exact name mismatch. The error lists your calendars; `ical calendars` shows them too. |

### Install

| Symptom | Fix |
|---|---|
| Homebrew says `ical` is "shadowed", or the wrong `ical` runs | Another binary named `ical` is earlier on your `PATH`. `which -a ical` shows them; remove the other one or call `$(brew --prefix)/bin/ical`. |
| `swift test` fails with no `XCTest` module | The Command Line Tools can build but not test. Use Xcode: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. |

## Configuration reference

| Setting | Env var | Flag | Default |
|---|---|---|---|
| Token | `CALENDAR_MCP_TOKEN` | | none |
| Token file | `CALENDAR_MCP_TOKEN_FILE` | | `~/.config/apple-calendar/token` |
| Client tokens | | | `~/.config/apple-calendar/tokens/<client>` |
| Bind address | `CALENDAR_MCP_HOST` | `--host` | `127.0.0.1` |
| Port | `CALENDAR_MCP_PORT` | `--port` | `3456` |
| Disable auth | | `--no-auth` | off |

All token sources are unioned: the env token, the default token file, and every file in
`tokens/` are valid at once, and any of them authorizes a request. Tokens are compared in
constant time. Token files are re-read on demand (at most every 5 seconds), so `token add`
and `token revoke` never need a restart.

`--no-auth` only consults `CALENDAR_MCP_TOKEN`; if that is set, auth stays on. With nothing
set, anyone who can reach the port can read and change your calendar. Use it only on an
isolated interface.

## Security model

- Read and write. There is no read-only mode. Anyone who can call the server can change your
  calendar, so treat the token like a password.
- Fail-closed. The HTTP server won't start without a token and rejects any request whose
  bearer header doesn't match one. If you revoke every token, it rejects every request.
- Per-client tokens. Each machine gets its own credential (`tokens/<client>`, mode 600).
  Revoke one and the others keep working; the running server notices within about 5 seconds.
  Every session is logged with the client that opened it.
- No transport encryption. It's plain HTTP. Run it on loopback or inside a VPN, never on the
  public internet.
- macOS permission pinned to the binary. Calendar access is granted per code identity. The
  binary is signed as `com.apple-calendar-mcp.cli` so one approval survives every upgrade.

## Uninstall

```bash
ical serve uninstall --purge       # stop and remove the LaunchAgent, delete all tokens
brew uninstall apple-calendar
brew untap hunterbrewer04/tap            # optional
rm -f ~/Library/Logs/apple-calendar.log
```

To revoke the Calendar permission too: System Settings → Privacy & Security → Calendars.

## Build from source

```bash
git clone https://github.com/hunterbrewer04/apple-calendar-mcp.git
cd apple-calendar-mcp
swift build -c release
codesign -s - --identifier com.apple-calendar-mcp.cli --force .build/release/apple-calendar
.build/release/apple-calendar today
```

Re-run the `codesign` step after every rebuild. The stable identity is what keeps the Calendar
permission valid across recompiles; Homebrew does this for you.

Tests need a full Xcode install (the Command Line Tools have no `XCTest`):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

CI runs the suite in both debug and release on every push. It can't exercise live EventKit
reads (a runner has no Calendar permission), so those are checked by running the binary locally.

## Claude Code skill

[`skill/SKILL.md`](skill/SKILL.md) teaches Claude Code on the Mac to answer calendar questions
by shelling out to `ical`: which command fits which question, how to find an event id before
editing, and what each error means. Install it by symlinking the folder from a clone of this
repo:

```bash
mkdir -p ~/.claude/skills && ln -s "$(pwd)/skill" ~/.claude/skills/apple-calendar
```

It's for the Mac that has `ical` installed. A Claude Code session on another machine should
use the MCP tools over the network instead.

## How it works

```
ical <subcommand>   →  CLI ─────────┐
ical mcp            →  stdio MCP ───┼─→  shared EventKit store  →  macOS calendar DB  (~100 ms)
ical mcp --http     →  HTTP MCP ────┘      (read + write)
                          ▲
                          └─ bearer token, fail-closed
```

A single EventKit store feeds all three front-ends. The MCP layer uses the official
[Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk) for the protocol and the
`stdio` transport, with a [Hummingbird](https://github.com/hummingbird-project/hummingbird)-backed
transport for the token-gated HTTP server. Each HTTP client gets its own MCP session; when the
session table fills, the least-recently-used ones are evicted.

## License

[MIT](LICENSE).
