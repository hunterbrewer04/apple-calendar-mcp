import Foundation

enum WindowError: Error, Equatable { case nonPositiveDays(Int) }

enum DateWindow {
    static let maxDays = 1460  // EventKit predicate ~4-year cap

    static func range(offsetDays: Int, days: Int, now: Date, calendar: Calendar)
        -> Result<(start: Date, end: Date), WindowError>
    {
        guard days > 0 else { return .failure(.nonPositiveDays(days)) }
        let clamped = min(days, maxDays)
        let dayStart = calendar.startOfDay(for: now)
        // Safe to force-unwrap: callers pass offsetDays ∈ {0,1} and days is clamped to
        // [1, 1460], so adding at most ~1461 days to a start-of-day can never overflow
        // Calendar.date(byAdding:) for any representable Date.
        let start = calendar.date(byAdding: .day, value: offsetDays, to: dayStart)!
        let end = calendar.date(byAdding: .day, value: clamped, to: start)!
        return .success((start, end))
    }

    static func sorted(_ events: [CalEvent]) -> [CalEvent] {
        events.sorted {
            $0.startDate != $1.startDate ? $0.startDate < $1.startDate : $0.title < $1.title
        }
    }
}
