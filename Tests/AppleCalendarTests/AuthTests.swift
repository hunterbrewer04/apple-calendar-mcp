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
        let c = ServerConfig.fromEnvironment([:], argv: [], readFile: { _ in nil })
        XCTAssertEqual(c.port, 3456)
        XCTAssertEqual(c.host, "127.0.0.1")
        XCTAssertNil(c.token)
        XCTAssertFalse(c.allowNoAuth)
    }
    func testFailsClosedWithoutToken() {
        let c = ServerConfig.fromEnvironment([:], argv: [], readFile: { _ in nil })
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
    func testReadsTokenFromDefaultFileWhenEnvAbsent() {
        let c = ServerConfig.fromEnvironment(
            [:], argv: [],
            readFile: { $0 == "/home/u/.config/apple-calendar/token" ? "filetoken\n" : nil },
            homeDir: "/home/u")
        XCTAssertEqual(c.token, "filetoken")           // trimmed
        XCTAssertNoThrow(try c.validate())
    }
    func testEnvTokenWinsOverFile() {
        let c = ServerConfig.fromEnvironment(
            ["CALENDAR_MCP_TOKEN": "envtoken"], argv: [],
            readFile: { _ in "filetoken" }, homeDir: "/home/u")
        XCTAssertEqual(c.token, "envtoken")
    }
    func testTokenFileEnvVarOverridesDefaultPath() {
        let c = ServerConfig.fromEnvironment(
            ["CALENDAR_MCP_TOKEN_FILE": "/custom/tok"], argv: [],
            readFile: { $0 == "/custom/tok" ? "customtoken" : nil },
            homeDir: "/home/u")
        XCTAssertEqual(c.token, "customtoken")
    }
    func testEmptyTokenFileFailsClosed() {
        let c = ServerConfig.fromEnvironment(
            [:], argv: [], readFile: { _ in "   \n" }, homeDir: "/home/u")
        XCTAssertNil(c.token)
        XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? StartupError, .missingToken) }
    }
}
