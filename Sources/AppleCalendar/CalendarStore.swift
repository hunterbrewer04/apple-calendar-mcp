import Foundation

enum StoreError: Error, Equatable {
    case accessDenied(String)
    case accessTimedOut(String)
    case calendarNotFound(name: String, available: [String])
    case window(WindowError)
    case internalError(String)
    case eventNotFound(id: String)
    case invalidInput(String)
    case writeFailed(String)
}

protocol CalendarStore {
    func ensureAccess() throws
    func calendars() -> [String]
    func events(offsetDays: Int, days: Int, calendarName: String?) throws -> [CalEvent]

    /// Create a new event. `draft.title`, `draft.start`, and `draft.end` are
    /// required (validated by the caller). `draft.calendarName` selects the
    /// target calendar; nil uses the default calendar for new events.
    func createEvent(_ draft: EventDraft) throws -> CalEvent

    /// Apply the non-nil fields of `changes` to the event with the given id.
    func updateEvent(id: String, changes: EventDraft) throws -> CalEvent

    /// Remove the event with the given id.
    func deleteEvent(id: String) throws
}
