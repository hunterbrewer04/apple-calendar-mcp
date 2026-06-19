import XCTest
@testable import apple_calendar

final class AuthTests: XCTestCase {
    func testRejectsMissingAndWrongHeader() {
        XCTAssertFalse(Auth.authorize(header: nil, token: "s3cret"))
        XCTAssertFalse(Auth.authorize(header: "Bearer nope", token: "s3cret"))
    }
    func testAcceptsExactBearer() {
        XCTAssertTrue(Auth.authorize(header: "Bearer s3cret", token: "s3cret"))
    }
    func testConfigDefaults() {
        let c = ServerConfig.fromEnvironment([:], argv: [])
        XCTAssertEqual(c.port, 3456)
        XCTAssertEqual(c.host, "127.0.0.1")
        XCTAssertNil(c.token)
        XCTAssertFalse(c.allowNoAuth)
    }
    func testFailsClosedWithoutToken() {
        let c = ServerConfig.fromEnvironment([:], argv: [])
        XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? StartupError, .missingToken) }
    }
    func testNoAuthFlagAllowsMissingToken() {
        let c = ServerConfig.fromEnvironment([:], argv: ["--no-auth"])
        XCTAssertNoThrow(try c.validate())
    }
    func testEnvOverrides() {
        let c = ServerConfig.fromEnvironment(
            ["CALENDAR_MCP_HOST": "100.1.1.1", "CALENDAR_MCP_PORT": "9000", "CALENDAR_MCP_TOKEN": "t"],
            argv: ["--http"])
        XCTAssertEqual(c.host, "100.1.1.1"); XCTAssertEqual(c.port, 9000); XCTAssertEqual(c.token, "t")
    }
}
