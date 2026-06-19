import Foundation

enum StoreError: Error, Equatable {
    case accessDenied(String)
    case accessTimedOut(String)
    case calendarNotFound(name: String, available: [String])
    case window(WindowError)
    case internalError(String)
}

protocol CalendarStore {
    func ensureAccess() throws
    func calendars() -> [String]
    func events(offsetDays: Int, days: Int, calendarName: String?) throws -> [CalEvent]
}
