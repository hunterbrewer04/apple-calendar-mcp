import EventKit
import Foundation

final class EventKitStore: CalendarStore {
    private let store = EKEventStore()

    func ensureAccess() throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return
        case .notDetermined:
            final class GrantBox: @unchecked Sendable { var granted = false }
            let box = GrantBox()
            let sema = DispatchSemaphore(value: 0)
            store.requestFullAccessToEvents { ok, _ in
                box.granted = ok
                sema.signal()
            }
            if sema.wait(timeout: .now() + 90) == .timedOut {
                throw StoreError.accessTimedOut(
                    "Calendar access request timed out — the macOS permission dialog was never answered. Run `ical today` in Terminal on the Mac and click \"Allow Full Access\".")
            }
            if box.granted { return }
            fallthrough
        default:
            throw StoreError.accessDenied(
                "Calendar access denied. Fix: System Settings → Privacy & Security → Calendars → enable access for this tool, then retry.")
        }
    }

    func calendars() -> [String] { store.calendars(for: .event).map(\.title) }

    func events(offsetDays: Int, days: Int, calendarName: String?) throws -> [CalEvent] {
        let cal = Calendar.current
        let range: (start: Date, end: Date)
        switch DateWindow.range(offsetDays: offsetDays, days: days, now: Date(), calendar: cal) {
        case .success(let r): range = r
        case .failure(let e): throw StoreError.window(e)
        }
        var matchingCalendars: [EKCalendar]? = nil  // nil = all calendars
        if let name = calendarName {
            let all = store.calendars(for: .event)
            let matches = all.filter { $0.title == name }
            if matches.isEmpty {
                throw StoreError.calendarNotFound(name: name, available: all.map(\.title).sorted())
            }
            matchingCalendars = matches
        }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: matchingCalendars)
        let mapped = store.events(matching: predicate).map {
            CalEvent(calendar: $0.calendar.title, title: $0.title ?? "",
                     startDate: $0.startDate, endDate: $0.endDate, isAllDay: $0.isAllDay,
                     location: $0.location, notes: $0.notes, url: $0.url)
        }
        return DateWindow.sorted(mapped)
    }
}
