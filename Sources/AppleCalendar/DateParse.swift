import Foundation

/// Parses the date strings accepted by the write tools/CLI into `Date`s.
///
/// Two shapes are accepted, both interpreted in the machine's current time zone
/// when no explicit zone is given:
///   - date-time: `2026-07-01T14:30`, `2026-07-01T14:30:00` (optional `Z`/offset)
///   - date-only: `2026-07-01` (used for all-day events; resolves to local midnight)
///
/// A leading/trailing-trimmed empty string and anything that matches neither
/// shape yields `.invalidInput`.
enum DateParse {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Date-time patterns tried in order. Each is built with a fresh formatter so
    /// the helper stays free of shared mutable state (matching `Renderer`).
    private static let dateTimePatterns = [
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mmZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
    ]
    private static let dateOnlyPattern = "yyyy-MM-dd"

    private static func parse(_ s: String, pattern: String) -> Date? {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = pattern
        return f.date(from: s)
    }

    /// Parse a date-time string (the `start`/`end` of a timed event).
    static func dateTime(_ raw: String) throws -> Date {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw StoreError.invalidInput("A date/time value was empty.") }
        for p in dateTimePatterns {
            if let d = parse(s, pattern: p) { return d }
        }
        throw StoreError.invalidInput(
            "Could not parse date/time '\(raw)'. Use ISO-8601, e.g. 2026-07-01T14:30.")
    }

    /// Parse a date-only string (the day of an all-day event), at local midnight.
    static func dateOnly(_ raw: String) throws -> Date {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw StoreError.invalidInput("A date value was empty.") }
        // Accept a full date-time too and truncate to its day, so callers can pass
        // either shape for an all-day event.
        if let d = parse(s, pattern: dateOnlyPattern) { return d }
        if let d = try? dateTime(s) {
            return Calendar.current.startOfDay(for: d)
        }
        throw StoreError.invalidInput(
            "Could not parse date '\(raw)'. Use a calendar date, e.g. 2026-07-01.")
    }
}
