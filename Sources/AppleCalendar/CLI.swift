import Foundation

enum Command: Equatable {
    case calendars
    case events(offsetDays: Int, days: Int, calendarName: String?)
    case raw(offsetDays: Int, days: Int)
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

    static func run(_ argv: [String], store: CalendarStore) -> (stdout: String?, stderr: String?, exitCode: Int32) {
        let (command, details) = parse(argv)
        do {
            switch command {
            case .usage:
                return (nil, "Usage: ical [today|tomorrow|week|month|next N|calendars|cal NAME [DAYS]|detail|debug] [-x]", 1)
            case .calendars:
                try store.ensureAccess()
                return (Renderer.calendars(store.calendars()), nil, 0)
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
        }
    }
}
