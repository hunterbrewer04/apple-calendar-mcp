---
name: apple-calendar
description: >
  Use this skill whenever the user asks about their Apple Calendar or schedule. Triggers on
  phrasings like "what's on my calendar", "pull from iCal", "do I have anything today/tomorrow",
  "check my schedule", "what meetings do I have", "what's this week look like", "any events
  coming up", "show me my calendar", or any request to look up, summarize, or reason about
  calendar events, or to add, change, or remove them ("put X on my calendar", "schedule …",
  "move my 3pm", "cancel …", "delete that event"). Uses the `ical` CLI — a compiled Swift binary
  that reads and writes the calendar database directly via Apple's EventKit framework (queries
  return in ~100ms; Calendar.app does not need to be running).
---

> **LOCAL USE ONLY** — this skill shells out to the on-Mac `ical` binary. Claude sessions on
> *other* machines should not use this skill; they reach the same data through the MCP server
> (`get_today`, `get_week`, …) over the private network. See this repo's `README.md`.

## Description

Query the user's Apple Calendar using the `ical` CLI and surface the results. The binary
queries the macOS calendar database directly through EventKit — no AppleScript, no
Calendar.app dependency, no external APIs. Queries are effectively instant, so never hesitate
to run several (e.g., `today` then `week`) to answer a question well.

## Prerequisites

- `ical` must be installed and on `PATH` (`brew install hunterbrewer04/tap/apple-calendar`).
- macOS Calendar (TCC) permission for the calling context — macOS may show a one-time
  permission dialog on first use; tell the user to click "Allow Full Access".
- Source lives in `~/Code/apple-calendar-mcp/`. Rebuilds from source MUST re-run the codesign
  step (`codesign -s - --identifier com.apple-calendar-mcp.cli --force <bin>`), or install via
  Homebrew, which codesigns automatically — the stable identity is what keeps the calendar
  permission valid across recompiles.

## Process

### 1. Map intent to command

| User asks about... | Command |
|--------------------|---------|
| Today's events | `ical today` |
| Tomorrow | `ical tomorrow` |
| This week | `ical week` |
| Next N days | `ical next N` |
| This month | `ical month` |
| A specific calendar | `ical cal "Calendar Name" [days]` |
| Which calendars exist | `ical calendars` |
| Notes, descriptions, URLs, **event ids** | Add `-x` to any command, or use `ical detail [period]` |
| Add an event | `ical add --title T --start ISO [--end ISO] [--all-day] [--cal NAME] [--location L] [--notes N] [--url U]` |
| Change an event | `ical edit ID [--title …] [--start …] [--end …] [--all-day] [--cal …] [--location …] [--notes …] [--url …]` |
| Delete an event | `ical rm ID` |

When the user's timeframe is ambiguous, default to `today`. If they say "coming up" or
"upcoming" without a specific window, use `week`.

### Writing events (add / edit / delete)

- Dates are ISO-8601: `2026-07-01T14:30` for timed events, or a plain date `2026-07-01` with
  `--all-day`. The CLI rejects an end that is before the start.
- `edit` and `rm` need the event's **id**. Get it by first running a detailed listing
  (`ical detail today` or add `-x`) and reading the `🆔` line; never guess an id.
- `edit` changes only the fields you pass. To move a meeting, pass new `--start`/`--end`.
- Writes change the user's real calendar. Before deleting or rescheduling, confirm you have the
  right event (title, time, calendar), and prefer to echo back what you changed.

### 2. Run the command

Execute via Bash. Output is pre-formatted, chronologically sorted:

```
  Jun 3   1:30 PM – 2:30 PM  1:1 with Sarah
                             📍 Zoom
                             📅 Work
  Jun 3   all day            RENT / Utilities
                             📅 Bills / Subscriptions
```

Behaviors worth knowing when interpreting output:

- **Recurring events are expanded** — every instance in the window appears.
- **Ongoing multi-day events appear too** — an event that *started earlier* but overlaps the
  queried window shows up with its original start date (e.g., `tomorrow` may list a `Jun 2` row
  for a conference still running). That's correct, not a glitch — mention the event is ongoing
  when relaying it.
- Day counts ≤ 0 are rejected; counts above ~4 years are clamped (EventKit limit).

### 3. Present results

Relay the output directly. If there are no events, say so plainly. If the user asked a
follow-up question about the events (e.g., "which ones are in-person?", "when's my next meeting
after lunch?"), reason over the output to answer.

For queries that span multiple days, group your response by day if the raw output isn't already
clear.

### 4. Handle errors

The CLI exits non-zero with an actionable message on stderr — relay that message; it usually
contains the fix.

- **"Calendar access denied"**: Tell the user to open System Settings → Privacy & Security →
  Calendars and enable access for the app that ran the command (Terminal, Claude Code, etc.),
  then retry.
- **"permission dialog was never answered"**: A macOS dialog is (or was) waiting on screen — the
  user needs to click "Allow Full Access", then retry.
- **Command not found:** Install or reinstall with `brew install hunterbrewer04/tap/apple-calendar`.
- **"No events."**: Report it literally — don't fabricate or guess.
- **"Calendar 'X' not found"**: The error lists available calendar names — pick the right one or
  show the user the list.

## Output

Reproduce the `ical` output cleanly. For multi-day results or summaries, you may reformat into
prose if it reads more naturally — but never omit events or change times.
