import XCTest
@testable import apple_calendar

final class DateWindowTests: XCTestCase {
    let cal = Calendar(identifier: .gregorian)
    // 2026-06-18 12:00 local
    var now: Date { DateComponents(calendar: cal, year: 2026, month: 6, day: 18, hour: 12).date! }

    func testTodayRangeIsMidnightToNextMidnight() {
        let r = try! DateWindow.range(offsetDays: 0, days: 1, now: now, calendar: cal).get()
        XCTAssertEqual(cal.startOfDay(for: now), r.start)
        XCTAssertEqual(cal.date(byAdding: .day, value: 1, to: r.start), r.end)
    }

    func testTomorrowOffsetsByOneDay() {
        let r = try! DateWindow.range(offsetDays: 1, days: 1, now: now, calendar: cal).get()
        XCTAssertEqual(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)), r.start)
    }

    func testNonPositiveDaysRejected() {
        // Can't XCTAssertEqual the whole Result: its success type is a tuple
        // (start:Date, end:Date), and tuples aren't Equatable. Match the failure instead.
        let r = DateWindow.range(offsetDays: 0, days: 0, now: now, calendar: cal)
        guard case .failure(.nonPositiveDays(let d)) = r else {
            return XCTFail("expected .nonPositiveDays failure, got \(r)")
        }
        XCTAssertEqual(d, 0)
    }

    func testDaysClampedToMax() {
        let r = try! DateWindow.range(offsetDays: 0, days: 99999, now: now, calendar: cal).get()
        let span = cal.dateComponents([.day], from: r.start, to: r.end).day!
        XCTAssertEqual(span, DateWindow.maxDays)
    }

    func testSortIsChronologicalWithTitleTiebreak() {
        let a = CalEvent(calendar: "X", title: "B", startDate: now, endDate: now, isAllDay: false, location: nil, notes: nil, url: nil)
        let b = CalEvent(calendar: "X", title: "A", startDate: now, endDate: now, isAllDay: false, location: nil, notes: nil, url: nil)
        let earlier = CalEvent(calendar: "X", title: "Z", startDate: cal.date(byAdding: .hour, value: -1, to: now)!, endDate: now, isAllDay: false, location: nil, notes: nil, url: nil)
        XCTAssertEqual(DateWindow.sorted([a, b, earlier]).map(\.title), ["Z", "A", "B"])
    }
}
