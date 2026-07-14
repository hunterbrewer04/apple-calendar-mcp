import XCTest
@testable import apple_calendar

final class AuthTests: XCTestCase {
    // MARK: - Auth.authorize
    func testRejectsMissingAndWrongHeader() {
        let tokens = ["s3cret": "default"]
        XCTAssertNil(Auth.authorize(header: nil, tokens: tokens, open: false))
        XCTAssertNil(Auth.authorize(header: "Bearer nope", tokens: tokens, open: false))
    }
    func testAcceptsExactBearerAndReturnsClientName() {
        XCTAssertEqual(Auth.authorize(header: "Bearer s3cret",
                                      tokens: ["s3cret": "brewserver", "other": "env"],
                                      open: false), "brewserver")
    }
    func testEmptyTokenSetDeniesEverything() {
        // All tokens revoked at runtime: fail closed, even a stale-but-plausible header.
        XCTAssertNil(Auth.authorize(header: "Bearer anything", tokens: [:], open: false))
        XCTAssertNil(Auth.authorize(header: nil, tokens: [:], open: false))
    }
    func testOpenModeAdmitsEverythingAsAnonymous() {
        XCTAssertEqual(Auth.authorize(header: nil, tokens: [:], open: true), "anonymous")
        XCTAssertEqual(Auth.authorize(header: "Bearer junk", tokens: [:], open: true), "anonymous")
    }

    // MARK: - ServerConfig
    private func config(env: [String: String] = [:], argv: [String] = [],
                        files: [String: String] = [:], dir: [String] = []) -> ServerConfig {
        ServerConfig.fromEnvironment(env, argv: argv, readFile: { files[$0] },
                                     homeDir: "/home/u", listDir: { _ in dir })
    }
    func testConfigDefaults() {
        let c = config()
        XCTAssertEqual(c.port, 3456)
        XCTAssertEqual(c.host, "127.0.0.1")
        XCTAssertTrue(c.tokens.isEmpty)
        XCTAssertFalse(c.allowNoAuth)
        XCTAssertEqual(c.homeDir, "/home/u")
    }
    func testFailsClosedWithoutToken() {
        XCTAssertThrowsError(try config().validate()) { XCTAssertEqual($0 as? StartupError, .missingToken) }
    }
    func testNoAuthFlagAllowsMissingToken() {
        let c = config(argv: ["--no-auth"])
        XCTAssertNoThrow(try c.validate())
        XCTAssertTrue(c.isOpen)
    }
    func testEnvOverrides() {
        let c = config(env: ["CALENDAR_MCP_HOST": "100.1.1.1", "CALENDAR_MCP_PORT": "9000",
                             "CALENDAR_MCP_TOKEN": "t"], argv: ["--http"])
        XCTAssertEqual(c.host, "100.1.1.1"); XCTAssertEqual(c.port, 9000)
        XCTAssertEqual(c.tokens, ["t": "env"])
    }
    func testReadsTokenFromDefaultFileWhenEnvAbsent() {
        let c = config(files: ["/home/u/.config/apple-calendar/token": "filetoken\n"])
        XCTAssertEqual(c.tokens, ["filetoken": "default"])     // trimmed
        XCTAssertNoThrow(try c.validate())
    }
    func testEnvAndFileTokensBothValid() {
        // Multi-token semantics: sources are a union (v1.2.0 shadowing removed by design).
        let c = config(env: ["CALENDAR_MCP_TOKEN": "envtoken"],
                       files: ["/home/u/.config/apple-calendar/token": "filetoken"])
        XCTAssertEqual(c.tokens, ["envtoken": "env", "filetoken": "default"])
    }
    func testClientTokenDirIsLoaded() {
        let c = config(files: ["/home/u/.config/apple-calendar/tokens/brewserver": "brewtok\n"],
                       dir: ["brewserver"])
        XCTAssertEqual(c.tokens, ["brewtok": "brewserver"])
        XCTAssertNoThrow(try c.validate())
    }
    func testTokenFileEnvVarOverridesDefaultPath() {
        let c = config(env: ["CALENDAR_MCP_TOKEN_FILE": "/custom/tok"],
                       files: ["/custom/tok": "customtoken"])
        XCTAssertEqual(c.tokens, ["customtoken": "default"])
    }
    func testEmptyTokenFileFailsClosed() {
        let c = config(files: ["/home/u/.config/apple-calendar/token": "   \n"])
        XCTAssertTrue(c.tokens.isEmpty)
        XCTAssertThrowsError(try c.validate()) { XCTAssertEqual($0 as? StartupError, .missingToken) }
    }
    func testWhitespaceEnvTokenFallsThroughToFile() {
        let c = config(env: ["CALENDAR_MCP_TOKEN": "   "],
                       files: ["/home/u/.config/apple-calendar/token": "filetoken"])
        XCTAssertEqual(c.tokens, ["filetoken": "default"])
    }
    func testEmptyTokenFileEnvVarFallsBackToDefaultPath() {
        let c = config(env: ["CALENDAR_MCP_TOKEN_FILE": ""],
                       files: ["/home/u/.config/apple-calendar/token": "deftoken"])
        XCTAssertEqual(c.tokens, ["deftoken": "default"])
    }
    func testNoAuthWithTokenFilePresentIsOpen() {
        // --no-auth must yield a genuinely open server: file tokens are NOT consulted.
        let c = config(argv: ["--no-auth"],
                       files: ["/home/u/.config/apple-calendar/token": "filetoken",
                               "/home/u/.config/apple-calendar/tokens/brewserver": "brewtok"],
                       dir: ["brewserver"])
        XCTAssertTrue(c.tokens.isEmpty)
        XCTAssertTrue(c.isOpen)
        XCTAssertNoThrow(try c.validate())
    }
    func testNoAuthWithEnvTokenStillEnforced() {
        let c = config(env: ["CALENDAR_MCP_TOKEN": "envtoken"], argv: ["--no-auth"])
        XCTAssertEqual(c.tokens, ["envtoken": "env"])
        XCTAssertFalse(c.isOpen)
    }
    func testEnvTokenIsNotTrimmed() {
        let c = config(env: ["CALENDAR_MCP_TOKEN": " padded "])
        XCTAssertEqual(c.tokens, [" padded ": "env"])
    }
    func testArgvHostPortOverrideEnvAndBadPortFallsBack() {
        let c = config(env: ["CALENDAR_MCP_HOST": "10.0.0.9", "CALENDAR_MCP_PORT": "9000"],
                       argv: ["--host", "127.0.0.5", "--port", "7777"])
        XCTAssertEqual(c.host, "127.0.0.5")
        XCTAssertEqual(c.port, 7777)
        let bad = config(argv: ["--port", "notanumber"])
        XCTAssertEqual(bad.port, 3456)
    }
}
