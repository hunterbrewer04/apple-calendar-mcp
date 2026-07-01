import XCTest
import MCP
@testable import apple_calendar

/// An in-memory CalendarStore for exercising the write tools without EventKit.
/// Records the last draft/id it was handed and lets a test script its result.
final class MockCalendarStore: CalendarStore {
    var accessGranted = true
    var calendarNames = ["Work", "Personal"]
    var existingIds = Set(["evt-1"])

    private(set) var lastCreate: EventDraft?
    private(set) var lastUpdateId: String?
    private(set) var lastUpdate: EventDraft?
    private(set) var lastDeleteId: String?

    func ensureAccess() throws {
        if !accessGranted { throw StoreError.accessDenied("denied") }
    }

    func calendars() -> [String] { calendarNames }

    func events(offsetDays: Int, days: Int, calendarName: String?) throws -> [CalEvent] { [] }

    func createEvent(_ draft: EventDraft) throws -> CalEvent {
        lastCreate = draft
        guard let title = draft.title, !title.isEmpty else { throw StoreError.invalidInput("title required") }
        guard let start = draft.start else { throw StoreError.invalidInput("start required") }
        return CalEvent(id: "new-id", calendar: draft.calendarName ?? "Work", title: title,
                        startDate: start, endDate: draft.end ?? start, isAllDay: draft.isAllDay ?? false,
                        location: draft.location, notes: draft.notes, url: draft.url)
    }

    func updateEvent(id: String, changes: EventDraft) throws -> CalEvent {
        guard existingIds.contains(id) else { throw StoreError.eventNotFound(id: id) }
        lastUpdateId = id
        lastUpdate = changes
        let start = changes.start ?? Date(timeIntervalSince1970: 0)
        return CalEvent(id: id, calendar: changes.calendarName ?? "Work", title: changes.title ?? "Existing",
                        startDate: start, endDate: changes.end ?? start, isAllDay: changes.isAllDay ?? false,
                        location: changes.location, notes: changes.notes, url: changes.url)
    }

    func deleteEvent(id: String) throws {
        guard existingIds.contains(id) else { throw StoreError.eventNotFound(id: id) }
        lastDeleteId = id
    }
}

final class WriteToolsTests: XCTestCase {

    // MARK: - MCP tool dispatch

    func testCreateEventToolBuildsDraftAndConfirms() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "create_event", arguments: [
            "title": .string("Standup"),
            "start": .string("2026-07-01T09:00"),
            "end": .string("2026-07-01T09:15"),
            "calendar_name": .string("Work"),
            "location": .string("Zoom"),
        ])
        XCTAssertFalse(out.hasPrefix("Error:"), out)
        XCTAssertTrue(out.contains("Created"))
        XCTAssertTrue(out.contains("Standup"))
        XCTAssertEqual(mock.lastCreate?.title, "Standup")
        XCTAssertEqual(mock.lastCreate?.calendarName, "Work")
        XCTAssertEqual(mock.lastCreate?.location, "Zoom")
        XCTAssertNotNil(mock.lastCreate?.start)
        XCTAssertNotNil(mock.lastCreate?.end)
    }

    func testCreateEventMissingTitleIsError() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "create_event", arguments: [
            "start": .string("2026-07-01T09:00"),
            "end": .string("2026-07-01T09:15"),
        ])
        XCTAssertTrue(out.hasPrefix("Error:"), out)
        XCTAssertNil(mock.lastCreate)
    }

    func testCreateTimedEventMissingEndIsError() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "create_event", arguments: [
            "title": .string("X"),
            "start": .string("2026-07-01T09:00"),
        ])
        XCTAssertTrue(out.hasPrefix("Error:"), out)
    }

    func testCreateAllDayEventNeedsNoEnd() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "create_event", arguments: [
            "title": .string("Offsite"),
            "start": .string("2026-07-01"),
            "all_day": true,
        ])
        XCTAssertFalse(out.hasPrefix("Error:"), out)
        XCTAssertEqual(mock.lastCreate?.isAllDay, true)
    }

    func testCreateEventBadDateIsError() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "create_event", arguments: [
            "title": .string("X"),
            "start": .string("not-a-date"),
            "end": .string("2026-07-01T09:15"),
        ])
        XCTAssertTrue(out.hasPrefix("Error:"), out)
    }

    func testUpdateEventPartial() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "update_event", arguments: [
            "event_id": .string("evt-1"),
            "title": .string("Renamed"),
        ])
        XCTAssertFalse(out.hasPrefix("Error:"), out)
        XCTAssertEqual(mock.lastUpdateId, "evt-1")
        XCTAssertEqual(mock.lastUpdate?.title, "Renamed")
        XCTAssertNil(mock.lastUpdate?.start)   // partial: untouched fields stay nil
    }

    func testUpdateMissingIdIsError() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "update_event", arguments: ["title": .string("X")])
        XCTAssertTrue(out.hasPrefix("Error:"), out)
    }

    func testUpdateUnknownIdIsError() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "update_event", arguments: [
            "event_id": .string("missing"),
            "title": .string("X"),
        ])
        XCTAssertTrue(out.hasPrefix("Error:"), out)
    }

    func testDeleteEvent() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "delete_event", arguments: ["event_id": .string("evt-1")])
        XCTAssertFalse(out.hasPrefix("Error:"), out)
        XCTAssertEqual(mock.lastDeleteId, "evt-1")
    }

    func testDeleteUnknownIdIsError() {
        let mock = MockCalendarStore()
        let tools = MCPTools(store: mock)
        let out = tools.text(forTool: "delete_event", arguments: ["event_id": .string("nope")])
        XCTAssertTrue(out.hasPrefix("Error:"), out)
    }

    func testWriteToolsAreAdvertised() {
        let names = Set(MCPTools.definitions.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["create_event", "update_event", "delete_event"]))
    }

    // MARK: - CLI path

    func testCLIAddBuildsDraft() {
        let mock = MockCalendarStore()
        let r = CLI.run(["add", "--title", "Lunch", "--start", "2026-07-01T12:00",
                         "--end", "2026-07-01T13:00", "--cal", "Personal"], store: mock)
        XCTAssertEqual(r.exitCode, 0, r.stderr ?? "")
        XCTAssertEqual(mock.lastCreate?.title, "Lunch")
        XCTAssertEqual(mock.lastCreate?.calendarName, "Personal")
        XCTAssertTrue(r.stdout?.contains("Created") ?? false)
    }

    func testCLIEditAndRm() {
        let mock = MockCalendarStore()
        let edit = CLI.run(["edit", "evt-1", "--title", "New"], store: mock)
        XCTAssertEqual(edit.exitCode, 0, edit.stderr ?? "")
        XCTAssertEqual(mock.lastUpdate?.title, "New")

        let rm = CLI.run(["rm", "evt-1"], store: mock)
        XCTAssertEqual(rm.exitCode, 0, rm.stderr ?? "")
        XCTAssertEqual(mock.lastDeleteId, "evt-1")
    }

    func testCLIRmUnknownIdFails() {
        let mock = MockCalendarStore()
        let r = CLI.run(["rm", "ghost"], store: mock)
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertNotNil(r.stderr)
    }

    func testCLIAddTimedWithoutEndIsError() {
        let mock = MockCalendarStore()
        let r = CLI.run(["add", "--title", "X", "--start", "2026-07-01T09:00"], store: mock)
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertNil(mock.lastCreate)   // rejected before reaching the store
    }

    func testCLIAddAllDayWithoutEndSucceeds() {
        let mock = MockCalendarStore()
        let r = CLI.run(["add", "--title", "Offsite", "--start", "2026-07-01", "--all-day"], store: mock)
        XCTAssertEqual(r.exitCode, 0, r.stderr ?? "")
        XCTAssertEqual(mock.lastCreate?.isAllDay, true)
    }
}
