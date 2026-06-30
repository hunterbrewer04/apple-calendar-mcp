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

    // MARK: - Helpers

    /// Resolve an `EKCalendar` by exact title, throwing `.calendarNotFound` if
    /// no match. Shared by reads and writes.
    private func calendar(named name: String) throws -> EKCalendar {
        let all = store.calendars(for: .event)
        guard let match = all.first(where: { $0.title == name }) else {
            throw StoreError.calendarNotFound(name: name, available: all.map(\.title).sorted())
        }
        return match
    }

    private func map(_ ev: EKEvent) -> CalEvent {
        CalEvent(id: ev.eventIdentifier, calendar: ev.calendar.title, title: ev.title ?? "",
                 startDate: ev.startDate, endDate: ev.endDate, isAllDay: ev.isAllDay,
                 location: ev.location, notes: ev.notes, url: ev.url)
    }

    func events(offsetDays: Int, days: Int, calendarName: String?) throws -> [CalEvent] {
        let cal = Calendar.current
        let range: (start: Date, end: Date)
        switch DateWindow.range(offsetDays: offsetDays, days: days, now: Date(), calendar: cal) {
        case .success(let r): range = r
        case .failure(let e): throw StoreError.window(e)
        }
        var matchingCalendars: [EKCalendar]? = nil  // nil = all calendars
        if let name = calendarName {
            matchingCalendars = [try calendar(named: name)]
        }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: matchingCalendars)
        let mapped = store.events(matching: predicate).map(map)
        return DateWindow.sorted(mapped)
    }

    // MARK: - Writes

    func createEvent(_ draft: EventDraft) throws -> CalEvent {
        guard let title = draft.title, !title.isEmpty else {
            throw StoreError.invalidInput("An event title is required.")
        }
        guard let start = draft.start else {
            throw StoreError.invalidInput("An event start date is required.")
        }
        let ev = EKEvent(eventStore: store)
        if let name = draft.calendarName {
            ev.calendar = try calendar(named: name)
        } else if let def = store.defaultCalendarForNewEvents {
            ev.calendar = def
        } else {
            throw StoreError.writeFailed("No default calendar is available to create events in.")
        }
        try apply(draft, to: ev, defaultStart: start)
        do {
            try store.save(ev, span: .thisEvent, commit: true)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        return map(ev)
    }

    func updateEvent(id: String, changes: EventDraft) throws -> CalEvent {
        guard let ev = store.event(withIdentifier: id) else {
            throw StoreError.eventNotFound(id: id)
        }
        if let name = changes.calendarName { ev.calendar = try calendar(named: name) }
        try apply(changes, to: ev, defaultStart: nil)
        do {
            try store.save(ev, span: .thisEvent, commit: true)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        return map(ev)
    }

    func deleteEvent(id: String) throws {
        guard let ev = store.event(withIdentifier: id) else {
            throw StoreError.eventNotFound(id: id)
        }
        do {
            try store.remove(ev, span: .thisEvent, commit: true)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Apply the non-nil fields of `draft` onto `ev`. `defaultStart` is used by
    /// create so the (required) start is always set; update passes nil and only
    /// touches supplied fields. Validates `end >= start` when both are known.
    private func apply(_ draft: EventDraft, to ev: EKEvent, defaultStart: Date?) throws {
        if let title = draft.title { ev.title = title }
        if let isAllDay = draft.isAllDay { ev.isAllDay = isAllDay }
        let resolvedStart = draft.start ?? defaultStart
        if let start = resolvedStart { ev.startDate = start }
        if let end = draft.end {
            ev.endDate = end
        } else if ev.endDate == nil, let start = resolvedStart {
            // Create with no explicit end (all-day, or omitted): default to the
            // start so a freshly built EKEvent always has both endpoints set.
            ev.endDate = start
        }
        if ev.endDate < ev.startDate {
            throw StoreError.invalidInput("Event end (\(ev.endDate)) is before its start (\(ev.startDate)).")
        }
        if let location = draft.location { ev.location = location }
        if let notes = draft.notes { ev.notes = notes }
        if let url = draft.url { ev.url = url }
    }
}
