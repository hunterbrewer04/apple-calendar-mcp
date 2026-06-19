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
        default:
            return "Error: unknown tool \(name)"
        }
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
    ]
}

func makeServer(store: CalendarStore) async -> Server {
    let tools = MCPTools(store: store)
    let server = Server(
        name: "apple-calendar",
        version: "4.0.0",
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
