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

    // MARK: - Write subcommands

    func testAddParsesFlags() {
        let (cmd, _) = CLI.parse(["add", "--title", "Lunch", "--start", "2026-07-01T12:00",
                                  "--end", "2026-07-01T13:00", "--cal", "Personal"])
        XCTAssertEqual(cmd, .write(WriteArgs(kind: .create, allDay: false, fields: [
            "title": "Lunch", "start": "2026-07-01T12:00", "end": "2026-07-01T13:00", "cal": "Personal",
        ])))
    }

    func testAddAllDayBoolean() {
        let (cmd, _) = CLI.parse(["add", "--title", "Offsite", "--start", "2026-07-01", "--all-day"])
        XCTAssertEqual(cmd, .write(WriteArgs(kind: .create, allDay: true, fields: [
            "title": "Offsite", "start": "2026-07-01",
        ])))
    }

    func testEditCarriesId() {
        let (cmd, _) = CLI.parse(["edit", "evt-1", "--title", "New"])
        XCTAssertEqual(cmd, .write(WriteArgs(kind: .update(id: "evt-1"), allDay: false, fields: ["title": "New"])))
    }

    func testEditWithoutIdIsUsage() {
        XCTAssertEqual(CLI.parse(["edit", "--title", "New"]).command, .usage)
    }

    func testRmCarriesId() {
        XCTAssertEqual(CLI.parse(["rm", "evt-1"]).command, .write(WriteArgs(kind: .delete(id: "evt-1"))))
    }

    func testRmWithoutIdIsUsage() {
        XCTAssertEqual(CLI.parse(["rm"]).command, .usage)
    }

    func testLocationAliasNormalizes() {
        let (cmd, _) = CLI.parse(["add", "--title", "X", "--start", "2026-07-01T09:00",
                                  "--end", "2026-07-01T10:00", "--loc", "Cafe"])
        if case .write(let w) = cmd {
            XCTAssertEqual(w.fields["location"], "Cafe")
        } else {
            XCTFail("expected write command")
        }
    }
}
