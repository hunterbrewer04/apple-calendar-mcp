import Foundation

enum Renderer {
    private static let posix = Locale(identifier: "en_US_POSIX")

    // A fresh DateFormatter per call keeps Renderer free of mutable shared state,
    // so it stays non-isolated and is safe to call from the async MCP/HTTP handlers.
    // DateFormatter construction is cheap relative to the small outputs here.
    private static func fmt(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = pattern
        return f.string(from: date)
    }
    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    private static func clean(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "|", with: "/")
    }
    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }

    static func events(_ events: [CalEvent], details: Bool) -> String {
        guard !events.isEmpty else { return "  No events." }
        var lines: [String] = []
        for e in events {
            let date = fmt(e.startDate, "MMM d")
            let time = e.isAllDay ? "all day" : "\(fmt(e.startDate, "h:mm a")) – \(fmt(e.endDate, "h:mm a"))"
            lines.append("  \(pad(date, 6))  \(pad(time, 16))  \(oneLine(clean(e.title)))")
            var meta: [String] = []
            if let loc = e.location, !loc.isEmpty { meta.append("📍 \(oneLine(clean(loc)))") }
            meta.append("📅 \(e.calendar)")
            if details, let notes = e.notes {
                for para in notes.components(separatedBy: .newlines) {
                    let p = para.trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty { meta.append("   📝 \(p)") }
                }
            }
            if details, let url = e.url { meta.append("   🔗 \(url.absoluteString)") }
            if details, let id = e.id { meta.append("   🆔 \(id)") }
            for m in meta { lines.append("  \(pad("", 6))  \(pad("", 16))  \(m)") }
        }
        return lines.joined(separator: "\n")
    }

    /// One-line confirmation of a write, e.g.
    /// `Created "Standup" — Jun 3, 9:00 AM – 9:15 AM on Work (id: ABC123)`.
    static func confirmation(verb: String, event e: CalEvent) -> String {
        let date = fmt(e.startDate, "MMM d")
        let time = e.isAllDay ? "all day" : "\(fmt(e.startDate, "h:mm a")) – \(fmt(e.endDate, "h:mm a"))"
        let idPart = e.id.map { " (id: \($0))" } ?? ""
        return "\(verb) \"\(oneLine(e.title))\" — \(date), \(time) on \(e.calendar)\(idPart)"
    }

    static func raw(_ events: [CalEvent]) -> String {
        guard !events.isEmpty else { return "No events." }
        return events.map { e in
            let ds = fmt(e.startDate, "EEEE, MMMM d, yyyy")
            let ts = e.isAllDay ? "" : fmt(e.startDate, "h:mm:ss a")
            let te = e.isAllDay ? "" : fmt(e.endDate, "h:mm:ss a")
            let desc = clean(e.notes).replacingOccurrences(of: "\n", with: "¶")
            return "\(e.calendar)|\(ds)|\(ts)|\(te)|\(clean(e.title))|\(clean(e.location))|\(desc)|\(clean(e.url?.absoluteString))|\(e.id ?? "")"
        }.joined(separator: "\n")
    }

    static func calendars(_ names: [String]) -> String { names.joined(separator: "\n") }
}
