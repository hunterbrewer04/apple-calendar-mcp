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
    func testWhitespaceEnvTokenFallsThroughToFile() {
        // A fat-fingered CALENDAR_MCP_TOKEN=" " must not shadow a valid file token.
        let c = ServerConfig.fromEnvironment(
            ["CALENDAR_MCP_TOKEN": "   "], argv: [],
            readFile: { _ in "filetoken" }, homeDir: "/home/u")
        XCTAssertEqual(c.token, "filetoken")
    }
    func testCustomTokenFileEmptyFailsClosed() {
        let c = ServerConfig.fromEnvironment(
            ["CALENDAR_MCP_TOKEN_FILE": "/custom/tok"], argv: [],
            readFile: { $0 == "/custom/tok" ? "  \n" : nil }, homeDir: "/home/u")
        XCTAssertNil(c.token)
        XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? StartupError, .missingToken) }
    }
    func testEmptyTokenFileEnvVarFallsBackToDefaultPath() {
        // CALENDAR_MCP_TOKEN_FILE="" (e.g. an unset shell var) must not suppress the default file.
        let c = ServerConfig.fromEnvironment(
            ["CALENDAR_MCP_TOKEN_FILE": ""], argv: [],
            readFile: { $0 == "/home/u/.config/apple-calendar/token" ? "deftoken" : nil },
            homeDir: "/home/u")
        XCTAssertEqual(c.token, "deftoken")
    }
    func testNoAuthWithTokenFilePresentIsOpen() {
        // --no-auth must yield a genuinely open server: a leftover file token must NOT be read,
        // or the printed "running without auth" warning would be a lie.
        let c = ServerConfig.fromEnvironment(
            [:], argv: ["--no-auth"],
            readFile: { _ in "filetoken" }, homeDir: "/home/u")
        XCTAssertNil(c.token)                 // file not consulted under --no-auth
        XCTAssertNoThrow(try c.validate())    // allowed to start
    }
    func testNoAuthWithEnvTokenStillEnforced() {
        // Back-compat: --no-auth + an explicit env token keeps that token (enforced), as before.
        let c = ServerConfig.fromEnvironment(
            ["CALENDAR_MCP_TOKEN": "envtoken"], argv: ["--no-auth"],
            readFile: { _ in "filetoken" }, homeDir: "/home/u")
        XCTAssertEqual(c.token, "envtoken")
    }
    func testEnvTokenIsNotTrimmed() {
        // Exact legacy behavior: a whitespace-padded env token is used verbatim, not trimmed,
        // so already-configured clients aren't silently locked out on upgrade.
        let c = ServerConfig.fromEnvironment(
            ["CALENDAR_MCP_TOKEN": " padded "], argv: [],
            readFile: { _ in nil }, homeDir: "/home/u")
        XCTAssertEqual(c.token, " padded ")
    }
    func testArgvHostPortOverrideEnvAndBadPortFallsBack() {
        let c = ServerConfig.fromEnvironment(
            ["CALENDAR_MCP_HOST": "10.0.0.9", "CALENDAR_MCP_PORT": "9000"],
            argv: ["--host", "127.0.0.5", "--port", "7777"],
            readFile: { _ in nil }, homeDir: "/home/u")
        XCTAssertEqual(c.host, "127.0.0.5")   // argv wins over env
        XCTAssertEqual(c.port, 7777)
        let bad = ServerConfig.fromEnvironment(
            [:], argv: ["--port", "notanumber"], readFile: { _ in nil }, homeDir: "/home/u")
        XCTAssertEqual(bad.port, 3456)        // non-numeric --port falls back to default, no crash
    }
}
