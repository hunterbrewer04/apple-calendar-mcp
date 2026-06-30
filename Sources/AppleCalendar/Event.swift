import Foundation

struct CalEvent: Equatable {
    // EventKit's `eventIdentifier`. Surfaced so write tools can target a specific
    // event by id. Defaults to nil so synthetic events (e.g. test fixtures) and
    // existing call sites need not supply one.
    var id: String? = nil
    let calendar: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: URL?
}

/// A set of fields for creating or updating an event. For updates, only the
/// non-nil fields are applied (partial update). For creates the caller validates
/// that `title`, `start`, and `end` are present before handing this to the store.
struct EventDraft: Equatable {
    var calendarName: String? = nil
    var title: String? = nil
    var start: Date? = nil
    var end: Date? = nil
    var isAllDay: Bool? = nil
    var location: String? = nil
    var notes: String? = nil
    var url: URL? = nil
}
