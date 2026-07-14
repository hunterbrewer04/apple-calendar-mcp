# apple-calendar-mcp

> A fast, native Apple Calendar tool for macOS. One small binary is both an `ical` terminal
> command **and** an MCP server — so any MCP-compatible app can read **and change** your
> calendar, locally or from another machine on your private network.

It works against the macOS calendar database directly through EventKit (~100 ms per query), so
Calendar.app never has to be open and nothing leaves your machine.

- 🗓️ **Instant queries** — today, this week, a specific calendar, the next N days.
- ✏️ **Create, update, and delete events** — from the CLI or any MCP client.
- 🔌 **Two ways to connect** — a local `stdio` server, or an HTTP server other machines can reach.
- 🔐 **Per-client tokens** — each machine gets its own revocable credential; the server refuses to start with none.
- 🍺 **One-command install** — Homebrew builds, code-signs, and (optionally) runs it for you.

---

## Which mode do you need?

- **Same Mac** (the AI app runs where your calendar lives) → **Local (`stdio`)**. One JSON
  block, no token, no network. Jump to [Local setup](#mode-1--local-stdio).
- **Another machine** (laptop, server, phone, a remote Claude Code) → **Networked (HTTP)**.
  One command sets it up: `ical serve setup`. Jump to [Networked setup](#mode-2--networked-http).

---

## Contents

- [Which mode do you need?](#which-mode-do-you-need)
- [Requirements](#requirements)
- [Install](#install)
- [Using the `ical` command](#using-the-ical-command)
- [Using the MCP server](#using-the-mcp-server)
- [Connecting from another machine](#connecting-from-another-machine)
- [Running it securely over a VPN](#running-it-securely-over-a-vpn)
- [Manual / advanced setup](#manual--advanced-setup)
- [Configuration reference](#configuration-reference)
- [Security model](#security-model)
- [Build from source](#build-from-source)
- [How it works](#how-it-works)
- [License](#license)

---

## Requirements

- **macOS 14 (Sonoma) or newer** — it uses EventKit's full-access API.
- **Homebrew**, and the Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is
  *not* required.

---

## Install

```bash
brew install hunterbrewer04/tap/apple-calendar
```

This builds the binary from source, installs it as `ical`, and **code-signs it with a stable
identity** so the macOS Calendar permission keeps working across upgrades.

The **first time** the tool actually reads your calendar, macOS shows a one-time
**“Allow Full Access”** dialog — click it. (Nothing prompts during install itself.)

> **Heads-up:** if you already have another `ical` earlier in your `PATH`, Homebrew will tell you
> it's “shadowed.” Either remove the old one, or call this build by its full path
> (`$(brew --prefix)/bin/ical`).

---

## Using the `ical` command

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

| Command | Shows |
|---|---|
| `ical` / `ical today` | today (the default) |
| `ical tomorrow` | tomorrow |
| `ical week` | the next 7 days |
| `ical month` | the next 30 days |
| `ical next 14` | the next *N* days |
| `ical calendars` | the names of all your calendars |
| `ical cal "Work" 14` | one calendar by name (optional day count, default 7) |
| `ical detail week` | any period, with notes + URLs |
| `ical debug today` | raw, pipe-delimited output (for scripts) |

Add **`-x`** (or `--detail`) to any command to include event notes and URLs (and the event **id**,
which `edit`/`rm` need).

### Creating and changing events

```bash
# add a timed event
ical add --title "Standup" --start 2026-07-01T09:00 --end 2026-07-01T09:15 --cal "Work"

# add an all-day event
ical add --title "Offsite" --start 2026-07-01 --all-day --cal "Work"

# find an event's id, then edit or remove it
ical detail today            # note the 🆔 line
ical edit <id> --title "Standup (moved)" --start 2026-07-01T09:30 --end 2026-07-01T09:45
ical rm <id>
```

| Command | Does |
|---|---|
| `ical add --title T --start ISO [--end ISO] [--all-day] [--cal NAME] [--location L] [--notes N] [--url U]` | create an event |
| `ical edit ID [--title …] [--start …] [--end …] [--all-day] [--cal …] [--location …] [--notes …] [--url …]` | change the given fields of an event |
| `ical rm ID` | delete an event |

Dates are ISO-8601 (`2026-07-01T14:30`); for `--all-day` events pass a plain date (`2026-07-01`).
`edit` changes only the fields you pass and leaves the rest untouched.

> Recurring events are expanded to individual occurrences, and a multi-day event that started
> earlier still shows up (with its original start date) for as long as it overlaps the window.

---

## Using the MCP server

The same binary speaks the **Model Context Protocol (MCP)**, so an AI assistant or any
MCP-compatible app can call it as a tool. There are two modes.

### Mode 1 — Local (`stdio`)

Best when the app runs on the **same Mac**. The app launches the binary and talks to it over its
standard input/output — no network, no token. Add this to your MCP client's config file:

```json
{
  "mcpServers": {
    "apple-calendar": { "type": "stdio", "command": "ical", "args": ["mcp"] }
  }
}
```

### Mode 2 — Networked (HTTP)

For an app on another machine on your private network (see the
[VPN section](#running-it-securely-over-a-vpn) — never the open internet). One command does
everything:

```bash
brew install hunterbrewer04/tap/apple-calendar
ical serve setup --tailscale      # or: --host <your-private-ip>   (bare = loopback only)
```

`serve setup` generates a token (saved to `~/.config/apple-calendar/token`, chmod 600),
installs a background LaunchAgent bound to your chosen address, starts it, and prints the exact
client config to paste on the other machine. It **survives reboots and `brew upgrade`** — no
`launchctl setenv`, nothing to redo.

Manage it any time:

| Command | Does |
|---|---|
| `ical serve status` | is it up? (expects `401` = up + auth enforced) + re-prints client config |
| `ical serve token` | print the **default** token (`ical serve token \| pbcopy`) |
| `ical serve token add <client> [--force]` | mint a token for a named client (errors if it already exists, unless `--force`) |
| `ical serve token show <client>` | print that client's token (`ical serve token show brewserver \| pbcopy`) |
| `ical serve token revoke <client>` | delete a client's token — that machine loses access within ~5s |
| `ical serve token list` | list every client + a `sha256:` fingerprint (never prints raw tokens) |
| `ical serve connect <ssh-host>` | one-command setup of a remote machine's Claude Code |
| `ical serve uninstall` | stop and remove the background server (`--purge` also deletes all tokens) |

> The HTTP server is **fail-closed**: with no token resolvable it refuses to start. (You can pass
> `--no-auth` to override that, but only on a fully trusted, isolated interface.)

Logs go to `~/Library/Logs/apple-calendar.log`.

### Available tools

> The HTTP server handles **multiple concurrent clients and reconnects** — each MCP session is
> isolated — so several apps (and repeated connect/disconnect cycles) can point at it at once.

| Tool | What it does |
|---|---|
| `list_calendars` | the names of all calendars |
| `get_today` / `get_tomorrow` | a single day |
| `get_week` / `get_month` | the next 7 / 30 days |
| `get_next_days(days)` | the next *N* days |
| `get_calendar_events(calendar_name, days)` | one calendar by name |
| `create_event(title, start, end, …)` | create a new event |
| `update_event(event_id, …)` | change fields of an existing event |
| `delete_event(event_id)` | delete an event |

The read tools accept `details: true` to include notes, URLs, and each event's **id**. The write
tools take ISO-8601 dates (`2026-07-01T14:30`; a plain date like `2026-07-01` for `all_day` events);
`update_event`/`delete_event` reference an event by the `id` returned in a `details: true` listing.
`create_event` and `update_event` also accept `calendar_name`, `location`, `notes`, and `url`.

---

## Connecting from another machine

You can read your Mac's calendar from a laptop, server, or phone — as long as both devices are on
the same **private network** (see the VPN section below; never expose this to the open internet).

There are two sides to set up.

### On the Mac (the server)

Run one command — it generates the token, binds to your chosen private-network address, and
starts the background server (see [Mode 2](#mode-2--networked-http)):

```bash
ical serve setup --tailscale      # or --host <your-private-ip>   (with a VPN this is your VPN IP)
```

It prints the token and the ready-to-paste client config. Grab the token again any time with
`ical serve token`.

### On the other machine (the client)

If Claude Code runs the client and you have **key-based ssh** to it, wire it up in one command
**from the Mac** — no config editing on the other side:

```bash
ical serve connect brewserver      # any ssh host or ~/.ssh/config alias
```

It mints (or reuses, on a repeat run) a **token scoped to that ssh host** — not the shared
default token — then over ssh installs the `apple-calendar` MCP server into that host's Claude
Code (user scope) and probes the server *from* that host to confirm the server is reachable from
that machine and auth is enforced. The token travels only over the ssh channel. On a host without
key-based ssh, run `ical serve connect <host> --print` to print the `claude mcp add …` one-liner
to paste there yourself — it's built with that same per-host token.

Because each machine gets its own credential, you can cut one off without touching the rest:
`ical serve token revoke <host>` deletes just that host's token, and a running server rejects it
within ~5 seconds — every other connected client keeps working.

Otherwise — no ssh, or a client that isn't Claude Code — mint that client its own token by hand
with `ical serve token add <client>` (see the [`ical serve`](#mode-2--networked-http) table
above), then point the MCP client at the Mac's address and include the token as a bearer header:

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

A copy you can edit is in [`examples/mcp-config.json`](examples/mcp-config.json).

**Quick test from the other machine:**

```bash
# no token → 401 (good: it's locked)
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://YOUR-MAC-IP:3456/mcp \
  -H 'Accept: application/json, text/event-stream' -d '{}'

# with token → an initialize response
curl -s -X POST http://YOUR-MAC-IP:3456/mcp \
  -H 'Authorization: Bearer YOUR-TOKEN' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
```

---

## Running it securely over a VPN

The HTTP server speaks **plain HTTP with no transport encryption**, and it grants read **and write**
access to your whole calendar. **Do not expose port 3456 to the public internet.** Instead, put both
machines on a private VPN and bind the server to the VPN interface. Two good options:

### Option A — Tailscale (recommended)

[Tailscale](https://tailscale.com) gives every device a stable private IP in the `100.x.y.z`
range and handles all the networking for you.

1. **Install Tailscale on the Mac and on the client machine**, and sign both into the same
   account (“tailnet”).

2. **Find the Mac's tailnet IP:**

   ```bash
   tailscale ip -4        # e.g. 100.101.102.103
   ```

3. **Bind the server to it:**

   ```bash
   ical serve setup --tailscale      # reads `tailscale ip -4` for you
   ```

4. On the client, use `http://100.101.102.103:3456/mcp` in the config above.

5. **(Optional) Lock it down with a tailnet ACL** so only *your* devices can reach the port. In
   your Tailscale admin console policy file:

   ```jsonc
   {
     "acls": [
       // allow only your own devices to reach the calendar port on the Mac
       { "action": "accept", "src": ["autogroup:member"], "dst": ["YOUR-MAC:3456"] }
     ]
   }
   ```

### Option B — WireGuard

If you run your own [WireGuard](https://www.wireguard.com) network, the Mac has a WireGuard
interface address (for example `10.0.0.1`).

1. **Bind the server to the WireGuard interface address:**

   ```bash
   ical serve setup --host 10.0.0.1
   ```

2. On each peer that should reach it, **scope `AllowedIPs`** to just what's needed so only that
   route is sent over the tunnel — e.g. in the peer's WireGuard config:

   ```ini
   [Peer]
   # ...the Mac's public key + endpoint...
   AllowedIPs = 10.0.0.1/32
   ```

3. From a peer, use `http://10.0.0.1:3456/mcp` in the config above.

> Whichever VPN you use, the bearer token is still required — the VPN controls *who can reach the
> port*, and the token controls *who can use the server*.

---

## Manual / advanced setup

`ical serve setup` automates all of this. Here's what it does by hand, if you want to run the
server some other way.

<details>
<summary>Run the HTTP server manually (env token)</summary>

Start it by hand to try it out:

```bash
export CALENDAR_MCP_TOKEN="$(openssl rand -hex 16)"   # generate a token
ical mcp --http                                       # listens on 127.0.0.1:3456
```

Add `--host <ip>` / `--port <n>` (or the env vars from the
[configuration reference](#configuration-reference)) to bind elsewhere.

Check it's up (a request **without** the token should be rejected with `401`):

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:3456/mcp \
  -H 'Accept: application/json, text/event-stream' -d '{}'      # → 401
```

> ⚠️ There is deliberately **no `brew services` integration**: a brew-managed service plist is
> regenerated on upgrade, which would wipe any environment injected with `launchctl setenv` and
> leave the fail-closed server down. For anything persistent, use `ical serve setup` — its token
> *file* plus user-owned LaunchAgent survive reboots and `brew upgrade`; it's the supported path.

</details>

---

## Configuration reference

| Setting | Env var | Default | Notes |
|---|---|---|---|
| Token | `CALENDAR_MCP_TOKEN` | — | HTTP mode needs a token from **some** source — this env var, the token file below, or a client token; compared in constant time |
| Token file | `CALENDAR_MCP_TOKEN_FILE` | `~/.config/apple-calendar/token` | the legacy shared/default token; overrides the default path; `serve setup` writes it |
| Client tokens | — | `~/.config/apple-calendar/tokens/<client>` | one file per client, managed by `ical serve token` / `serve connect`; unioned with the sources above |
| Bind address | `CALENDAR_MCP_HOST` | `127.0.0.1` | set to your VPN IP to allow remote clients |
| Port | `CALENDAR_MCP_PORT` | `3456` | |

All token sources are a **union** — the env token, the default file, and every named client file
in `tokens/` are valid at once; any of them authorizes a request.

On the command line: `--host`, `--port`, and `--no-auth` (run without a token — see the
security model below).

---

## Security model

- **Read *and* write.** The tool can query events and also create, update, and delete them. There
  is no read-only mode — anyone who can call the server can change your calendar, so treat access
  to it (and its token) accordingly.
- **Token required, fail-closed.** The HTTP server won't start without a resolvable token from
  any source, and rejects any request whose `Authorization: Bearer …` header doesn't match
  (constant-time compare). Because the HTTP server also exposes the write tools, keeping tokens
  secret matters more than ever.
- **Per-client tokens, unioned.** The env token, the default token file, and every named file in
  `~/.config/apple-calendar/tokens/` are all valid at once — any of them authorizes a request, and
  each is checked with the same constant-time comparison. Every session is logged with the client
  it matched (`session <id> client=<name>` in `~/Library/Logs/apple-calendar.log`), and revoking a
  token (`ical serve token revoke <client>`) takes effect on a running server within ~5 seconds —
  no restart. If every token is revoked, the server rejects every request.
- **No built-in encryption.** HTTP mode is plain HTTP — only run it on a trusted private network
  (loopback or a VPN), never on the public internet.
- **macOS permission, pinned to the binary.** Calendar access is granted by macOS per code
  identity. The binary is signed with a stable identifier (`com.apple-calendar-mcp.cli`) so the
  grant survives upgrades — you approve it once.

---

## Build from source

```bash
git clone https://github.com/hunterbrewer04/apple-calendar-mcp.git
cd apple-calendar-mcp
swift build -c release
codesign -s - --identifier com.apple-calendar-mcp.cli --force .build/release/apple-calendar
```

Re-run the `codesign` step after **every** rebuild — the stable identity is what keeps the
calendar permission valid across recompiles. (Homebrew does this for you automatically.)

> A full Swift toolchain runs the test suite (`swift test`). The Command Line Tools alone can
> build and run the binary but can't run the tests; they run in CI on every push.

---

## How it works

```
ical <subcommand>   →  CLI ───────┐
ical mcp            →  stdio MCP ──┼─→  shared EventKit store  →  macOS calendar DB  (~100 ms)
ical mcp --http     →  HTTP MCP ───┘      (read + write)
                          ▲
                          └─ bearer token, fail-closed
```

A single EventKit store feeds both front-ends. The MCP layer uses the official
[Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk) for the protocol and the
`stdio` transport, with a [Hummingbird](https://github.com/hummingbird-project/hummingbird)-backed
transport for the token-gated HTTP server.

---

## License

[MIT](LICENSE).
