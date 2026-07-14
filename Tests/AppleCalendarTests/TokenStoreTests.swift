import XCTest
@testable import apple_calendar

final class TokenStoreTests: XCTestCase {
    // MARK: - Client-name validation
    func testValidClientNames() {
        for ok in ["brewserver", "micro-server", "a", "Host.1", "user_box", "x" + String(repeating: "y", count: 63)] {
            XCTAssertTrue(TokenStore.isValidClientName(ok), ok)
        }
    }
    func testInvalidClientNames() {
        for bad in ["", ".DS_Store", "-lead", "_lead", "has space", "a/b", "../up", "über",
                    "x" + String(repeating: "y", count: 64)] {
            XCTAssertFalse(TokenStore.isValidClientName(bad), bad)
        }
    }
    func testSSHHostSanitization() {
        XCTAssertEqual(TokenStore.clientName(forSSHHost: "brewserver"), "brewserver")
        XCTAssertEqual(TokenStore.clientName(forSSHHost: "hunter@micro-server"), "micro-server")
        XCTAssertEqual(TokenStore.clientName(forSSHHost: "host.ts.net"), "host.ts.net")
        // Invalid chars collapse to '-', leading junk trimmed, never empty.
        XCTAssertEqual(TokenStore.clientName(forSSHHost: "we!rd~host"), "we-rd-host")
        XCTAssertTrue(TokenStore.isValidClientName(TokenStore.clientName(forSSHHost: "@@@")))
    }
    func testFingerprintShape() {
        let fp = TokenStore.fingerprint("abc")
        XCTAssertTrue(fp.hasPrefix("sha256:"))
        XCTAssertEqual(fp.count, "sha256:".count + 12)
        XCTAssertEqual(fp, TokenStore.fingerprint("abc"))       // deterministic
        XCTAssertNotEqual(fp, TokenStore.fingerprint("abd"))
    }

    // MARK: - load()
    private func load(env: [String: String] = [:], allowNoAuth: Bool = false,
                      files: [String: String] = [:], dir: [String] = []) -> [String: String] {
        TokenStore.load(env: env, homeDir: "/home/u", allowNoAuth: allowNoAuth,
                        readFile: { files[$0] }, listDir: { _ in dir })
    }
    func testLoadUnionOfAllSources() {
        let tokens = load(
            env: ["CALENDAR_MCP_TOKEN": "envtok"],
            files: ["/home/u/.config/apple-calendar/token": "deftok\n",
                    "/home/u/.config/apple-calendar/tokens/brewserver": "brewtok\n",
                    "/home/u/.config/apple-calendar/tokens/micro-server": "microtok"],
            dir: ["brewserver", "micro-server"])
        XCTAssertEqual(tokens, ["envtok": "env", "deftok": "default",
                                "brewtok": "brewserver", "microtok": "micro-server"])
    }
    func testLoadSkipsEmptyClientFiles() {
        let tokens = load(files: ["/home/u/.config/apple-calendar/tokens/ghost": "  \n"], dir: ["ghost"])
        XCTAssertTrue(tokens.isEmpty)
    }
    func testTokenFileEnvVarStillOverridesDefaultPath() {
        let tokens = load(env: ["CALENDAR_MCP_TOKEN_FILE": "/custom/tok"],
                          files: ["/custom/tok": "customtok"])
        XCTAssertEqual(tokens, ["customtok": "default"])
    }
    func testNoAuthConsultsOnlyEnv() {
        let tokens = load(env: ["CALENDAR_MCP_TOKEN": "envtok"], allowNoAuth: true,
                          files: ["/home/u/.config/apple-calendar/token": "deftok",
                                  "/home/u/.config/apple-calendar/tokens/brewserver": "brewtok"],
                          dir: ["brewserver"])
        XCTAssertEqual(tokens, ["envtok": "env"])
    }
    func testDuplicateTokenValueLastSortedNameWins() {
        let tokens = load(files: ["/home/u/.config/apple-calendar/tokens/aaa": "same",
                                  "/home/u/.config/apple-calendar/tokens/bbb": "same"],
                          dir: ["aaa", "bbb"])
        XCTAssertEqual(tokens, ["same": "bbb"])
    }

    // MARK: - TokenCache TTL
    func testCacheReloadsOnlyAfterTTL() async {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 0)
        let cache = TokenCache(ttl: 5, now: { clock }) {
            counter.n += 1
            return ["t\(counter.n)": "c"]
        }
        _ = await cache.current()
        clock = Date(timeIntervalSince1970: 4)
        let second = await cache.current()
        XCTAssertEqual(counter.n, 1)                    // within TTL: no reload
        XCTAssertEqual(second, ["t1": "c"])
        clock = Date(timeIntervalSince1970: 6)
        let third = await cache.current()
        XCTAssertEqual(counter.n, 2)                    // past TTL: reloaded
        XCTAssertEqual(third, ["t2": "c"])
    }
}
