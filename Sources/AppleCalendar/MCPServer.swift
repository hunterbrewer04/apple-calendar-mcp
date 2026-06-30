import Foundation
import MCP

struct MCPTools: @unchecked Sendable {
    let store: CalendarStore

    private func render(offsetDays: Int, days: Int, name: String?, details: Bool) -> String {
        do {
            try store.ensureAccess()
            let events = try store.events(offsetDays: offsetDays, days: days, calendarName: name)
            return Renderer.events(events, details: details)
        } catch let e as StoreError { return "Error: \(CLI.message(for: e))" }
        catch { return "Error: \(error)" }
    }

    func text(forTool name: String, arguments: [String: Value]) -> String {
        let details = arguments["details"]?.boolValue ?? false
        switch name {
        case "list_calendars":
            do {
                try store.ensureAccess()
                return Renderer.calendars(store.calendars())
            } catch let e as StoreError { return "Error: \(CLI.message(for: e))" }
            catch { return "Error: \(error)" }
        case "get_today":
            return render(offsetDays: 0, days: 1, name: nil, details: details)
        case "get_tomorrow":
            return render(offsetDays: 1, days: 1, name: nil, details: details)
        case "get_week":
            return render(offsetDays: 0, days: 7, name: nil, details: details)
        case "get_month":
            return render(offsetDays: 0, days: 30, name: nil, details: details)
        case "get_next_days":
            let days = arguments["days"]?.intValue ?? 7
            return render(offsetDays: 0, days: days, name: nil, details: details)
        case "get_calendar_events":
            guard let cal = arguments["calendar_name"]?.stringValue, !cal.isEmpty else {
                return "Error: calendar_name is required."
            }
            let days = arguments["days"]?.intValue ?? 7
            return render(offsetDays: 0, days: days, name: cal, details: details)
        case "create_event":
            return write {
                guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                    throw StoreError.invalidInput("title is required.")
                }
                guard arguments["start"]?.stringValue?.isEmpty == false else {
                    throw StoreError.invalidInput("start is required.")
                }
                let allDay = arguments["all_day"]?.boolValue ?? false
                if !allDay, arguments["end"]?.stringValue?.isEmpty != false {
                    throw StoreError.invalidInput("end is required for a timed event (or set all_day=true).")
                }
                var draft = try Self.draft(from: arguments, allDay: allDay)
                draft.title = title
                let event = try store.createEvent(draft)
                return Renderer.confirmation(verb: "Created", event: event)
            }
        case "update_event":
            return write {
                guard let id = arguments["event_id"]?.stringValue, !id.isEmpty else {
                    throw StoreError.invalidInput("event_id is required.")
                }
                let allDay = arguments["all_day"]?.boolValue ?? false
                let changes = try Self.draft(from: arguments, allDay: allDay)
                let event = try store.updateEvent(id: id, changes: changes)
                return Renderer.confirmation(verb: "Updated", event: event)
            }
        case "delete_event":
            return write {
                guard let id = arguments["event_id"]?.stringValue, !id.isEmpty else {
                    throw StoreError.invalidInput("event_id is required.")
                }
                try store.deleteEvent(id: id)
                return "Deleted event \(id)."
            }
        default:
            return "Error: unknown tool \(name)"
        }
    }

    /// Run a write closure, mapping thrown `StoreError`s to the `"Error: …"`
    /// text convention the CallTool handler keys `isError` on.
    private func write(_ body: () throws -> String) -> String {
        do {
            try store.ensureAccess()
            return try body()
        } catch let e as StoreError { return "Error: \(CLI.message(for: e))" }
        catch { return "Error: \(error)" }
    }

    /// Build an `EventDraft` from tool arguments, parsing dates and the URL.
    /// Only keys that are present are populated, so this serves both create
    /// (caller adds the required title) and partial update.
    private static func draft(from arguments: [String: Value], allDay: Bool) throws -> EventDraft {
        var draft = EventDraft()
        if let title = arguments["title"]?.stringValue { draft.title = title }
        if arguments["all_day"] != nil { draft.isAllDay = allDay }
        if let s = arguments["start"]?.stringValue, !s.isEmpty {
            draft.start = allDay ? try DateParse.dateOnly(s) : try DateParse.dateTime(s)
        }
        if let s = arguments["end"]?.stringValue, !s.isEmpty {
            draft.end = allDay ? try DateParse.dateOnly(s) : try DateParse.dateTime(s)
        }
        if let name = arguments["calendar_name"]?.stringValue, !name.isEmpty { draft.calendarName = name }
        if let loc = arguments["location"]?.stringValue { draft.location = loc }
        if let notes = arguments["notes"]?.stringValue { draft.notes = notes }
        if let u = arguments["url"]?.stringValue, !u.isEmpty {
            guard let url = URL(string: u) else { throw StoreError.invalidInput("url '\(u)' is not a valid URL.") }
            draft.url = url
        }
        return draft
    }

    // MARK: - Tool schema helpers

    private static func detailsProperty() -> Value {
        .object([
            "details": .object([
                "type": "boolean",
                "description": "Include event notes and URLs",
                "default": false,
            ])
        ])
    }

    static let definitions: [Tool] = [
        Tool(
            name: "list_calendars",
            description: "List all available Apple Calendars by name.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "required": .array([]),
            ])
        ),
        Tool(
            name: "get_today",
            description: "Today's events. details=true adds notes/URLs.",
            inputSchema: .object([
                "type": "object",
                "properties": detailsProperty(),
            ])
        ),
        Tool(
            name: "get_tomorrow",
            description: "Tomorrow's events. details=true adds notes/URLs.",
            inputSchema: .object([
                "type": "object",
                "properties": detailsProperty(),
            ])
        ),
        Tool(
            name: "get_week",
            description: "This week (next 7 days). details=true adds notes/URLs.",
            inputSchema: .object([
                "type": "object",
                "properties": detailsProperty(),
            ])
        ),
        Tool(
            name: "get_month",
            description: "This month (next 30 days). details=true adds notes/URLs.",
            inputSchema: .object([
                "type": "object",
                "properties": detailsProperty(),
            ])
        ),
        Tool(
            name: "get_next_days",
            description: "Events for the next N days. details=true adds notes/URLs.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "days": .object([
                        "type": "integer",
                        "description": "Number of days to look ahead",
                    ]),
                    "details": .object([
                        "type": "boolean",
                        "description": "Include event notes and URLs",
                        "default": false,
                    ]),
                ]),
                "required": .array([.string("days")]),
            ])
        ),
        Tool(
            name: "get_calendar_events",
            description: "Events from a specific calendar by name.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "calendar_name": .object([
                        "type": "string",
                        "description": "Name of the calendar to query",
                    ]),
                    "days": .object([
                        "type": "integer",
                        "description": "Number of days to look ahead (default 7)",
                    ]),
                    "details": .object([
                        "type": "boolean",
                        "description": "Include event notes and URLs",
                        "default": false,
                    ]),
                ]),
                "required": .array([.string("calendar_name")]),
            ])
        ),
        Tool(
            name: "create_event",
            description: "Create a new calendar event. Dates are ISO-8601 (e.g. 2026-07-01T14:30); for all_day events use a date like 2026-07-01.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "title": .object([
                        "type": "string",
                        "description": "Event title",
                    ]),
                    "start": .object([
                        "type": "string",
                        "description": "Start date/time, ISO-8601 (e.g. 2026-07-01T14:30). For all_day, a date like 2026-07-01.",
                    ]),
                    "end": .object([
                        "type": "string",
                        "description": "End date/time, ISO-8601. Required unless all_day is true.",
                    ]),
                    "all_day": .object([
                        "type": "boolean",
                        "description": "Create an all-day event",
                        "default": false,
                    ]),
                    "calendar_name": .object([
                        "type": "string",
                        "description": "Calendar to add the event to (defaults to the system default calendar)",
                    ]),
                    "location": .object(["type": "string", "description": "Event location"]),
                    "notes": .object(["type": "string", "description": "Event notes"]),
                    "url": .object(["type": "string", "description": "Event URL"]),
                ]),
                "required": .array([.string("title"), .string("start")]),
            ])
        ),
        Tool(
            name: "update_event",
            description: "Update fields of an existing event by id. Only the fields you pass are changed. Get the event_id from a detailed listing (details=true).",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "event_id": .object([
                        "type": "string",
                        "description": "The id of the event to update (from a details=true listing)",
                    ]),
                    "title": .object(["type": "string", "description": "New title"]),
                    "start": .object(["type": "string", "description": "New start date/time, ISO-8601"]),
                    "end": .object(["type": "string", "description": "New end date/time, ISO-8601"]),
                    "all_day": .object([
                        "type": "boolean",
                        "description": "Interpret start/end as all-day dates",
                        "default": false,
                    ]),
                    "calendar_name": .object(["type": "string", "description": "Move the event to this calendar"]),
                    "location": .object(["type": "string", "description": "New location"]),
                    "notes": .object(["type": "string", "description": "New notes"]),
                    "url": .object(["type": "string", "description": "New URL"]),
                ]),
                "required": .array([.string("event_id")]),
            ])
        ),
        Tool(
            name: "delete_event",
            description: "Delete an event by id. Get the event_id from a detailed listing (details=true).",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "event_id": .object([
                        "type": "string",
                        "description": "The id of the event to delete (from a details=true listing)",
                    ]),
                ]),
                "required": .array([.string("event_id")]),
            ])
        ),
    ]
}

func makeServer(store: CalendarStore) async -> Server {
    let tools = MCPTools(store: store)
    let server = Server(
        name: "apple-calendar",
        version: "5.0.0",
        capabilities: .init(tools: .init(listChanged: false))
    )
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: MCPTools.definitions)
    }
    await server.withMethodHandler(CallTool.self) { params in
        let out = tools.text(forTool: params.name, arguments: params.arguments ?? [:])
        return .init(
            content: [.text(text: out, annotations: nil, _meta: nil)],
            isError: out.hasPrefix("Error:")
        )
    }
    return server
}
