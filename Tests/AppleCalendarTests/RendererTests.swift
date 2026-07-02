import XCTest
@testable import apple_calendar

final class RendererTests: XCTestCase {
    let cal = Calendar(identifier: .gregorian)
    func d(_ h: Int, _ m: Int) -> Date {
        DateComponents(calendar: cal, year: 2026, month: 6, day: 3, hour: h, minute: m).date!
    }

    func testEmpty() {
        XCTAssertEqual(Renderer.events([], details: false), "  No events.")
    }

    func testTimedEventRowAndMeta() {
        // Assert on content, not exact column whitespace (matching the sibling tests): the row
        // carries date + time range + title, and location/calendar render on their own lines.
        let e = CalEvent(calendar: "Work", title: "1:1 with Sarah",
                         startDate: d(13, 30), endDate: d(14, 30), isAllDay: false,
                         location: "Zoom", notes: nil, url: nil)
        let out = Renderer.events([e], details: false)
        XCTAssertTrue(out.contains("Jun 3"))
        XCTAssertTrue(out.contains("1:30 PM – 2:30 PM"))
        XCTAssertTrue(out.contains("1:1 with Sarah"))
        XCTAssertTrue(out.contains("📍 Zoom"))
        XCTAssertTrue(out.contains("📅 Work"))
    }

    func testAllDayAndPipeSanitization() {
        let e = CalEvent(calendar: "Bills | Subs", title: "RENT | Utilities",
                         startDate: d(0, 0), endDate: d(0, 0), isAllDay: true,
                         location: nil, notes: nil, url: nil)
        let out = Renderer.events([e], details: false)
        XCTAssertTrue(out.contains("all day"))
        XCTAssertTrue(out.contains("RENT / Utilities"))
        XCTAssertTrue(out.contains("📅 Bills / Subs"))
    }

    func testDetailsAddsNotesAndURL() {
        let e = CalEvent(calendar: "Work", title: "Standup",
                         startDate: d(9, 0), endDate: d(9, 15), isAllDay: false,
                         location: nil, notes: "line1\nline2", url: URL(string: "https://x.test"))
        let out = Renderer.events([e], details: true)
        XCTAssertTrue(out.contains("📝 line1"))
        XCTAssertTrue(out.contains("📝 line2"))
        XCTAssertTrue(out.contains("🔗 https://x.test"))
    }

    func testCalendarsOnePerLine() {
        XCTAssertEqual(Renderer.calendars(["A", "B"]), "A\nB")
    }
}
