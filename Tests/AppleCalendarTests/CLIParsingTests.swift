import XCTest
@testable import apple_calendar

final class CLIParsingTests: XCTestCase {
    func testDefaultIsToday() {
        let (cmd, details) = CLI.parse([])
        XCTAssertEqual(cmd, .events(offsetDays: 0, days: 1, calendarName: nil))
        XCTAssertFalse(details)
    }
    func testWeekWithDetailFlag() {
        let (cmd, details) = CLI.parse(["week", "-x"])
        XCTAssertEqual(cmd, .events(offsetDays: 0, days: 7, calendarName: nil))
        XCTAssertTrue(details)
    }
    func testTomorrow() {
        XCTAssertEqual(CLI.parse(["tomorrow"]).command, .events(offsetDays: 1, days: 1, calendarName: nil))
    }
    func testNextN() {
        XCTAssertEqual(CLI.parse(["next", "10"]).command, .events(offsetDays: 0, days: 10, calendarName: nil))
    }
    func testNextDefaultsTo7OnGarbage() {
        XCTAssertEqual(CLI.parse(["next", "abc"]).command, .events(offsetDays: 0, days: 7, calendarName: nil))
    }
    func testCalNameAndDays() {
        XCTAssertEqual(CLI.parse(["cal", "Work", "14"]).command,
                       .events(offsetDays: 0, days: 14, calendarName: "Work"))
    }
    func testDetailForcesDetails() {
        let (cmd, details) = CLI.parse(["detail", "week"])
        XCTAssertEqual(cmd, .events(offsetDays: 0, days: 7, calendarName: nil))
        XCTAssertTrue(details)
    }
    func testDebugIsRaw() {
        XCTAssertEqual(CLI.parse(["debug", "tomorrow"]).command, .raw(offsetDays: 1, days: 1))
    }
    func testCalendars() {
        XCTAssertEqual(CLI.parse(["calendars"]).command, .calendars)
    }
}
