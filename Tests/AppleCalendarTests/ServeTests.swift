import XCTest
@testable import apple_calendar

final class ServeTests: XCTestCase {
    func testPaths() {
        XCTAssertEqual(Serve.configDir(home: "/h"), "/h/.config/apple-calendar")
        XCTAssertEqual(Serve.tokenPath(home: "/h"), "/h/.config/apple-calendar/token")
        XCTAssertEqual(Serve.plistPath(home: "/h"), "/h/Library/LaunchAgents/com.apple-calendar-mcp.plist")
        XCTAssertEqual(Serve.logPath(home: "/h"), "/h/Library/Logs/apple-calendar.log")
    }

    func testXmlEscape() {
        XCTAssertEqual(Serve.xmlEscape("a&b<c>\"d"), "a&amp;b&lt;c&gt;&quot;d")
    }

    func testPlistXMLContainsArgsAndIsEscaped() {
        let xml = Serve.plistXML(binaryPath: "/opt/homebrew/opt/apple-calendar/bin/ical",
                                 host: "100.1.2.3", port: 3456, logPath: "/h/Library/Logs/apple-calendar.log")
        XCTAssertTrue(xml.contains("<string>com.apple-calendar-mcp</string>"))
        XCTAssertTrue(xml.contains("<string>--http</string>"))
        XCTAssertTrue(xml.contains("<string>--host</string>"))
        XCTAssertTrue(xml.contains("<string>100.1.2.3</string>"))
        XCTAssertTrue(xml.contains("<string>3456</string>"))
        XCTAssertTrue(xml.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(xml.contains("<key>KeepAlive</key>"))
    }

    func testClientConfigJSON() {
        let json = Serve.clientConfigJSON(host: "100.1.2.3", port: 3456, token: "abc")
        XCTAssertTrue(json.contains("\"url\": \"http://100.1.2.3:3456/mcp\""))
        XCTAssertTrue(json.contains("\"Authorization\": \"Bearer abc\""))
        XCTAssertTrue(json.contains("\"type\": \"http\""))
    }

    func testClaudeMcpAddCommand() {
        let cmd = Serve.claudeMcpAddCommand(host: "100.1.2.3", port: 3456, token: "abc")
        XCTAssertTrue(cmd.contains("claude mcp add --transport http"))
        XCTAssertTrue(cmd.contains("http://100.1.2.3:3456/mcp"))
        XCTAssertTrue(cmd.contains("Authorization: Bearer abc"))
    }

    func testResolveHostExplicitWins() {
        let r = Serve.resolveHost(explicitHost: "10.0.0.1", useTailscale: false, useLocal: false, tailscaleIP: { "100.1.1.1" })
        XCTAssertEqual(try? r.get(), "10.0.0.1")
    }
    func testResolveHostTailscale() {
        let r = Serve.resolveHost(explicitHost: nil, useTailscale: true, useLocal: false, tailscaleIP: { "100.1.1.1" })
        XCTAssertEqual(try? r.get(), "100.1.1.1")
    }
    func testResolveHostTailscaleMissing() {
        let r = Serve.resolveHost(explicitHost: nil, useTailscale: true, useLocal: false, tailscaleIP: { nil })
        XCTAssertEqual(r, .failure(.tailscaleUnavailable))
    }
    func testResolveHostDefaultIsLoopback() {
        let r = Serve.resolveHost(explicitHost: nil, useTailscale: false, useLocal: false, tailscaleIP: { "100.1.1.1" })
        XCTAssertEqual(try? r.get(), "127.0.0.1")   // secure-by-default: ignore an available tailnet IP unless asked
    }
    func testResolveHostConflict() {
        let r = Serve.resolveHost(explicitHost: "10.0.0.1", useTailscale: true, useLocal: false, tailscaleIP: { nil })
        XCTAssertEqual(r, .failure(.conflictingHostFlags))
    }

    func testResolveBinaryPrefersOptPath() {
        let (path, warn) = Serve.resolveBinaryPath(argv0: "/some/build/.build/release/apple-calendar",
                                                   fileExists: { $0 == "/opt/homebrew/opt/apple-calendar/bin/ical" })
        XCTAssertEqual(path, "/opt/homebrew/opt/apple-calendar/bin/ical")
        XCTAssertNil(warn)
    }
    func testResolveBinaryWarnsOnBuildArtifact() {
        let (path, warn) = Serve.resolveBinaryPath(argv0: "/some/build/.build/release/apple-calendar",
                                                   fileExists: { _ in false })
        XCTAssertEqual(path, "/some/build/.build/release/apple-calendar")
        XCTAssertNotNil(warn)
        // The warning's contract is that it names the dangling path and points at Homebrew.
        XCTAssertTrue(warn?.contains("/some/build/.build/release/apple-calendar") == true)
        XCTAssertTrue(warn?.contains("Homebrew") == true)
    }
    func testResolveBinaryNoWarnForNonBuildPath() {
        // Installed at a non-Homebrew, non-build path: return argv0 with NO spurious warning.
        let (path, warn) = Serve.resolveBinaryPath(argv0: "/usr/local/bin/ical", fileExists: { _ in false })
        XCTAssertEqual(path, "/usr/local/bin/ical")
        XCTAssertNil(warn)
    }
    func testResolveBinaryPrefersIntelOptPath() {
        // Intel Homebrew installs under /usr/local; that opt path must be preferred too.
        let (path, warn) = Serve.resolveBinaryPath(argv0: "/some/build/.build/release/apple-calendar",
                                                   fileExists: { $0 == "/usr/local/opt/apple-calendar/bin/ical" })
        XCTAssertEqual(path, "/usr/local/opt/apple-calendar/bin/ical")
        XCTAssertNil(warn)
    }

    func testGenerateTokenIsHexOfRightLength() {
        let t = Serve.generateToken(byteCount: 32)
        XCTAssertEqual(t.count, 64)
        XCTAssertTrue(t.allSatisfy { "0123456789abcdef".contains($0) })
    }
    func testGenerateTokenIsUnique() {
        // A broken RNG emitting all-zeros would still pass the length+charset test, so a
        // bearer-token generator needs an entropy check: two calls differ and aren't a
        // constant run (e.g. all "0").
        let a = Serve.generateToken(), b = Serve.generateToken()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.allSatisfy { $0 == a.first })
    }

    func testResolveHostLocalFlag() {
        // Explicit --local: distinct branch from the secure-by-default fallthrough.
        let r = Serve.resolveHost(explicitHost: nil, useTailscale: false, useLocal: true, tailscaleIP: { "100.1.1.1" })
        XCTAssertEqual(try? r.get(), "127.0.0.1")
    }
    func testResolveHostConflictHostAndLocal() {
        let r = Serve.resolveHost(explicitHost: "10.0.0.1", useTailscale: false, useLocal: true, tailscaleIP: { nil })
        XCTAssertEqual(r, .failure(.conflictingHostFlags))
    }
    func testResolveHostTailscaleBlankOutputFailsClosed() {
        let r = Serve.resolveHost(explicitHost: nil, useTailscale: true, useLocal: false, tailscaleIP: { "  \n" })
        XCTAssertEqual(r, .failure(.tailscaleUnavailable))
    }
    func testResolveHostTailscaleTrimsIP() {
        // `tailscale ip -4` realistically returns a trailing newline; it must be trimmed.
        let r = Serve.resolveHost(explicitHost: nil, useTailscale: true, useLocal: false, tailscaleIP: { "100.1.1.1\n" })
        XCTAssertEqual(try? r.get(), "100.1.1.1")
    }

    func testPlistXMLEscapesPathValues() {
        // Exercise xmlEscape *inside* plistXML: a home dir / path with & and < must be escaped
        // so the generated plist stays well-formed.
        let xml = Serve.plistXML(binaryPath: "/opt/R&D/ical", host: "127.0.0.1",
                                 port: 3456, logPath: "/h/Logs/a<b.log")
        XCTAssertTrue(xml.contains("<string>/opt/R&amp;D/ical</string>"))
        XCTAssertTrue(xml.contains("/h/Logs/a&lt;b.log"))
        XCTAssertFalse(xml.contains("/opt/R&D/ical"))   // raw ampersand must not survive
    }
}
