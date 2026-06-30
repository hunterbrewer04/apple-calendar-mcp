import XCTest
@testable import apple_calendar

final class DateParseTests: XCTestCase {
    private let cal = Calendar.current

    func testDateTimeWithoutSeconds() throws {
        let d = try DateParse.dateTime("2026-07-01T14:30")
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 7)
        XCTAssertEqual(c.day, 1)
        XCTAssertEqual(c.hour, 14)
        XCTAssertEqual(c.minute, 30)
    }

    func testDateTimeWithSeconds() throws {
        let d = try DateParse.dateTime("2026-07-01T14:30:15")
        XCTAssertEqual(cal.component(.second, from: d), 15)
    }

    func testDateTimeWithExplicitZoneParses() throws {
        // Just assert it parses; the instant is normalized to a Date.
        XCTAssertNoThrow(try DateParse.dateTime("2026-07-01T14:30:00Z"))
        XCTAssertNoThrow(try DateParse.dateTime("2026-07-01T14:30:00+02:00"))
    }

    func testDateOnlyIsLocalMidnight() throws {
        let d = try DateParse.dateOnly("2026-07-01")
        XCTAssertEqual(d, cal.startOfDay(for: d))
        let c = cal.dateComponents([.year, .month, .day], from: d)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 7)
        XCTAssertEqual(c.day, 1)
    }

    func testDateOnlyAcceptsDateTimeAndTruncates() throws {
        let d = try DateParse.dateOnly("2026-07-01T23:59")
        XCTAssertEqual(d, cal.startOfDay(for: d))
        XCTAssertEqual(cal.component(.day, from: d), 1)
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try DateParse.dateTime("   "))
        XCTAssertThrowsError(try DateParse.dateOnly(""))
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try DateParse.dateTime("next tuesday"))
        XCTAssertThrowsError(try DateParse.dateOnly("07/01/2026"))
    }
}
