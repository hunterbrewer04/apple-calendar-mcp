import Foundation

/// A parsed write request from the CLI. Dates are kept as raw strings here so
/// `parse` stays pure/non-throwing and unit-testable; `run` parses them.
struct WriteArgs: Equatable {
    enum Kind: Equatable {
        case create
        case update(id: String)
        case delete(id: String)
    }
    var kind: Kind
    var allDay: Bool = false
    var fields: [String: String] = [:]   // title, start, end, cal, location, notes, url
}

enum Command: Equatable {
    case calendars
    case events(offsetDays: Int, days: Int, calendarName: String?)
    case raw(offsetDays: Int, days: Int)
    case write(WriteArgs)
    case usage
}

enum CLI {
    static func parse(_ argv: [String]) -> (command: Command, details: Bool) {
        var args = argv
        let details = args.contains("-x") || args.contains("--detail")
        args.removeAll { $0 == "-x" || $0 == "--detail" }
        let cmd = args.first ?? "today"
        let rest = Array(args.dropFirst())

        func sub(_ s: String) -> (offsetDays: Int, days: Int) {
            switch s {
            case "tomorrow": return (1, 1)
            case "week", "thisweek": return (0, 7)
            case "next": return (0, rest.count > 1 ? (Int(rest[1]) ?? 7) : 7)
            default: return (0, 1)
            }
        }

        switch cmd {
        case "calendars": return (.calendars, details)
        case "today": return (.events(offsetDays: 0, days: 1, calendarName: nil), details)
        case "tomorrow": return (.events(offsetDays: 1, days: 1, calendarName: nil), details)
        case "week", "thisweek": return (.events(offsetDays: 0, days: 7, calendarName: nil), details)
        case "month": return (.events(offsetDays: 0, days: 30, calendarName: nil), details)
        case "next":
            let days = rest.first.flatMap(Int.init) ?? 7
            return (.events(offsetDays: 0, days: days, calendarName: nil), details)
        case "cal", "calendar":
            guard let name = rest.first, !name.isEmpty else { return (.usage, details) }
            let days = rest.count > 1 ? (Int(rest[1]) ?? 7) : 7
            return (.events(offsetDays: 0, days: days, calendarName: name), details)
        case "add":
            let (allDay, fields) = writeFlags(rest)
            return (.write(WriteArgs(kind: .create, allDay: allDay, fields: fields)), details)
        case "edit":
            guard let id = rest.first, !id.isEmpty, !id.hasPrefix("--") else { return (.usage, details) }
            let (allDay, fields) = writeFlags(Array(rest.dropFirst()))
            return (.write(WriteArgs(kind: .update(id: id), allDay: allDay, fields: fields)), details)
        case "rm", "delete":
            guard let id = rest.first, !id.isEmpty, !id.hasPrefix("--") else { return (.usage, details) }
            return (.write(WriteArgs(kind: .delete(id: id))), details)
        case "detail", "details", "notes":
            let s = sub(rest.first ?? "today")
            return (.events(offsetDays: s.offsetDays, days: s.days, calendarName: nil), true)
        case "debug":
            let s = sub(rest.first ?? "today")
            return (.raw(offsetDays: s.offsetDays, days: s.days), details)
        default:
            return (.usage, details)
        }
    }

    /// Parse `--flag value` pairs and the `--all-day` boolean from write args.
    /// Unknown flags are ignored. Flag aliases are normalized to canonical keys.
    static func writeFlags(_ args: [String]) -> (allDay: Bool, fields: [String: String]) {
        var allDay = false
        var fields: [String: String] = [:]
        let aliases: [String: String] = [
            "--title": "title", "--start": "start", "--end": "end",
            "--cal": "cal", "--calendar": "cal", "--location": "location",
            "--loc": "location", "--notes": "notes", "--url": "url",
        ]
        var i = 0
        while i < args.count {
            let tok = args[i]
            if tok == "--all-day" || tok == "--allday" {
                allDay = true
                i += 1
            } else if let key = aliases[tok], i + 1 < args.count {
                fields[key] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        return (allDay, fields)
    }

    /// Build an `EventDraft` from parsed CLI write flags, parsing dates/URL.
    static func draft(from w: WriteArgs) throws -> EventDraft {
        var draft = EventDraft()
        if let t = w.fields["title"] { draft.title = t }
        if w.allDay { draft.isAllDay = true }
        if let s = w.fields["start"] {
            draft.start = w.allDay ? try DateParse.dateOnly(s) : try DateParse.dateTime(s)
        }
        if let e = w.fields["end"] {
            draft.end = w.allDay ? try DateParse.dateOnly(e) : try DateParse.dateTime(e)
        }
        if let c = w.fields["cal"] { draft.calendarName = c }
        if let l = w.fields["location"] { draft.location = l }
        if let n = w.fields["notes"] { draft.notes = n }
        if let u = w.fields["url"], !u.isEmpty {
            guard let url = URL(string: u) else { throw StoreError.invalidInput("url '\(u)' is not a valid URL.") }
            draft.url = url
        }
        return draft
    }

    static func run(_ argv: [String], store: CalendarStore) -> (stdout: String?, stderr: String?, exitCode: Int32) {
        let (command, details) = parse(argv)
        do {
            switch command {
            case .usage:
                return (nil, """
                Usage: ical [today|tomorrow|week|month|next N|calendars|cal NAME [DAYS]|detail|debug] [-x]
                       ical add --title T --start ISO [--end ISO] [--all-day] [--cal NAME] [--location L] [--notes N] [--url U]
                       ical edit ID [--title T] [--start ISO] [--end ISO] [--all-day] [--cal NAME] [--location L] [--notes N] [--url U]
                       ical rm ID
                """, 1)
            case .calendars:
                try store.ensureAccess()
                return (Renderer.calendars(store.calendars()), nil, 0)
            case .write(let w):
                try store.ensureAccess()
                switch w.kind {
                case .create:
                    if !w.allDay, (w.fields["end"]?.isEmpty ?? true) {
                        throw StoreError.invalidInput("--end is required for a timed event (or pass --all-day).")
                    }
                    let event = try store.createEvent(Self.draft(from: w))
                    return (Renderer.confirmation(verb: "Created", event: event), nil, 0)
                case .update(let id):
                    let event = try store.updateEvent(id: id, changes: Self.draft(from: w))
                    return (Renderer.confirmation(verb: "Updated", event: event), nil, 0)
                case .delete(let id):
                    try store.deleteEvent(id: id)
                    return ("Deleted event \(id).", nil, 0)
                }
            case .events(let off, let days, let name):
                try store.ensureAccess()
                let events = try store.events(offsetDays: off, days: days, calendarName: name)
                return (Renderer.events(events, details: details), nil, 0)
            case .raw(let off, let days):
                try store.ensureAccess()
                let events = try store.events(offsetDays: off, days: days, calendarName: nil)
                return (Renderer.raw(events), nil, 0)
            }
        } catch let e as StoreError {
            return (nil, Self.message(for: e), 1)
        } catch {
            return (nil, "Internal error: \(error)", 1)
        }
    }

    static func message(for e: StoreError) -> String {
        switch e {
        case .accessDenied(let m), .accessTimedOut(let m), .internalError(let m): return m
        case .calendarNotFound(let name, let available):
            return "Calendar '\(name)' not found. Available: \(available.joined(separator: ", "))"
        case .window(.nonPositiveDays(let d)): return "Day count must be at least 1 (got \(d))."
        case .eventNotFound(let id): return "No event found with id '\(id)'."
        case .invalidInput(let m): return m
        case .writeFailed(let m): return "Could not save change: \(m)"
        }
    }
}
