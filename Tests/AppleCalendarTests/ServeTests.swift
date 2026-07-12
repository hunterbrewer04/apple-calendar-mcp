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

    func testClientConfigJSONEscapesSpecialChars() throws {
        // A token/host with quotes, backslashes, or newlines must still yield parseable JSON
        // and round-trip to the original value — otherwise the pasted client config is broken.
        let json = Serve.clientConfigJSON(host: "1.2.3.4", port: 3456, token: "a\"b\\c\nd")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let headers = ((obj?["mcpServers"] as? [String: Any])?["apple-calendar"] as? [String: Any])?["headers"] as? [String: Any]
        XCTAssertEqual(headers?["Authorization"] as? String, "Bearer a\"b\\c\nd")
    }

    func testClaudeMcpAddCommandSingleQuotesAndEscapes() {
        // The header must be single-quoted (no $VAR/backtick expansion) with an embedded single
        // quote encoded as '\'' — so a hostile/odd token can't inject shell or break the command.
        let cmd = Serve.claudeMcpAddCommand(host: "1.2.3.4", port: 3456, token: "a'b$c\"d")
        XCTAssertTrue(cmd.contains("--header 'Authorization: Bearer a'\\''b$c\"d'"))
        XCTAssertFalse(cmd.contains("\"Authorization"))   // no leftover double-quote wrapping
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

    func testResolveBinaryResolvesBareNameOnPath() {
        // `ical` invoked from $PATH: argv0 is the bare name; it must be resolved to the absolute
        // path found on $PATH so the LaunchAgent (which does no $PATH lookup) can start it.
        let (path, warn) = Serve.resolveBinaryPath(
            argv0: "ical",
            fileExists: { $0 == "/custom/bin/ical" },   // not an opt path → found via PATH search
            cwd: "/work", pathEnv: "/usr/bin:/custom/bin")
        XCTAssertEqual(path, "/custom/bin/ical")
        XCTAssertNil(warn)
    }
    func testResolveBinaryResolvesRelativePathAgainstCwd() {
        // `.build/release/apple-calendar` is relative to cwd; it must be absolutized (and still
        // flagged as a source build).
        let (path, warn) = Serve.resolveBinaryPath(
            argv0: ".build/release/apple-calendar",
            fileExists: { _ in false }, cwd: "/work/proj", pathEnv: nil)
        XCTAssertEqual(path, "/work/proj/.build/release/apple-calendar")
        XCTAssertTrue(warn?.contains("/work/proj/.build/release/apple-calendar") == true)
    }
    func testResolveBinaryUnresolvableBareNameWarns() {
        // Bare name not found anywhere on $PATH: we can't fabricate an absolute path, so return
        // argv0 unchanged WITH a warning rather than silently emitting a plist that won't start.
        let (path, warn) = Serve.resolveBinaryPath(
            argv0: "ical", fileExists: { _ in false }, cwd: "/work", pathEnv: "/usr/bin:/bin")
        XCTAssertEqual(path, "ical")
        XCTAssertTrue(warn?.contains("could not resolve an absolute path") == true)
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

    // MARK: - serve connect

    func testRemoteConnectScriptEmbedsSingleQuotedURLAndToken() {
        let s = Serve.remoteConnectScript(host: "100.1.2.3", port: 3456, token: "abc")
        XCTAssertTrue(s.contains("'http://100.1.2.3:3456/mcp'"))
        XCTAssertTrue(s.contains("'Authorization: Bearer abc'"))
        // The reachability gate must use a bash-safe string comparison against 401.
        XCTAssertTrue(s.contains("[ \"$code\" = \"401\" ]"))
        XCTAssertTrue(s.contains("claude mcp add --transport http --scope user apple-calendar"))
        XCTAssertTrue(s.contains("exit 40"))
        XCTAssertTrue(s.contains("exit 41"))
    }

    func testRemoteConnectScriptEscapesHostileToken() {
        // A token with a single quote / backslash must be encoded via '\'' so it can't break out
        // of the single-quoted argument and inject shell.
        let s = Serve.remoteConnectScript(host: "1.2.3.4", port: 3456, token: "a'b\\c")
        XCTAssertTrue(s.contains("'Authorization: Bearer a'\\''b\\c'"))
        // The literal token followed by an unescaped quote must never appear.
        XCTAssertFalse(s.contains("Bearer a'b"))
    }

    func testSshConnectArgsShape() {
        let script = "echo hi"
        let args = Serve.sshConnectArgs(sshHost: "brewserver", script: script)
        XCTAssertEqual(args, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                              "brewserver", "bash", "-lc", "'echo hi'"])
        // The whole script is ONE argv element (single-quoted), so the remote shell re-parses it
        // as a single command rather than splitting it on spaces.
        XCTAssertEqual(args.last, Serve.shellSingleQuote(script))
    }

    func testSshConnectArgsScriptWithQuotesIsOneEscapedElement() {
        let script = Serve.remoteConnectScript(host: "1.2.3.4", port: 3456, token: "abc")
        let args = Serve.sshConnectArgs(sshHost: "host", script: script)
        XCTAssertEqual(args.count, 8)
        // Even though the script itself is full of single quotes, it survives as a single arg.
        XCTAssertEqual(args.last, Serve.shellSingleQuote(script))
    }

    func testParseConnectArgsMissingHost() {
        XCTAssertEqual(Serve.parseConnectArgs([]), .failure(.missingHost))
        XCTAssertEqual(Serve.parseConnectArgs(["--print"]), .failure(.missingHost))
    }

    func testParseConnectArgsHostAndPrintAnyOrder() {
        XCTAssertEqual(Serve.parseConnectArgs(["brewserver"]),
                       .success(Serve.ConnectArgs(sshHost: "brewserver", printOnly: false)))
        XCTAssertEqual(Serve.parseConnectArgs(["brewserver", "--print"]),
                       .success(Serve.ConnectArgs(sshHost: "brewserver", printOnly: true)))
        XCTAssertEqual(Serve.parseConnectArgs(["--print", "brewserver"]),
                       .success(Serve.ConnectArgs(sshHost: "brewserver", printOnly: true)))
    }

    func testParseConnectArgsRejectsUnknownFlag() {
        XCTAssertEqual(Serve.parseConnectArgs(["brewserver", "--nope"]), .failure(.unknownFlag("--nope")))
    }

    func testParseConnectArgsRejectsExtraPositional() {
        XCTAssertEqual(Serve.parseConnectArgs(["a", "b"]), .failure(.unexpectedArg("b")))
    }

    func testParseConnectArgsRejectsDashHost() {
        // A host beginning with '-' would be parsed by OpenSSH as an option (e.g. -oProxyCommand=...)
        // and could execute an arbitrary local command; the parser must reject it.
        XCTAssertEqual(Serve.parseConnectArgs(["-oProxyCommand=touch /tmp/pwned"]),
                       .failure(.invalidHost("-oProxyCommand=touch /tmp/pwned")))
        XCTAssertEqual(Serve.parseConnectArgs(["-J", "jump"]), .failure(.invalidHost("-J")))
    }

    func testConnectResultMessageSuccess() {
        let (out, err, code) = Serve.connectResultMessage(
            code: 0, sshHost: "brewserver", url: "http://100.1.2.3:3456/mcp",
            childOut: "connected", childErr: "")
        XCTAssertEqual(code, 0)
        XCTAssertNil(err)
        XCTAssertTrue(out?.contains("brewserver") == true)
        XCTAssertTrue(out?.contains("http://100.1.2.3:3456/mcp") == true)
    }

    func testConnectResultMessageClaudeMissing() {
        let (out, err, code) = Serve.connectResultMessage(
            code: 40, sshHost: "brewserver", url: "http://1.2.3.4:3456/mcp",
            childOut: "", childErr: "claude CLI not found on this host (login-shell PATH)")
        XCTAssertEqual(code, 40)
        XCTAssertNil(out)
        XCTAssertTrue(err?.contains("claude CLI was not found") == true)
        XCTAssertTrue(err?.contains("Install Claude Code") == true)
    }

    func testConnectResultMessageUnreachableIncludesStderr() {
        let (out, err, code) = Serve.connectResultMessage(
            code: 41, sshHost: "brewserver", url: "http://1.2.3.4:3456/mcp",
            childOut: "", childErr: "probe from this host returned 000 (expected 401)")
        XCTAssertEqual(code, 41)
        XCTAssertNil(out)
        XCTAssertTrue(err?.contains("could not reach the server") == true)
        XCTAssertTrue(err?.contains("curl is not installed") == true)   // curl-missing hint
        XCTAssertTrue(err?.contains("probe from this host returned 000") == true)
    }

    func testConnectResultMessageSshFailure() {
        let (out, err, code) = Serve.connectResultMessage(
            code: 255, sshHost: "brewserver", url: "http://1.2.3.4:3456/mcp",
            childOut: "", childErr: "Permission denied (publickey).")
        XCTAssertEqual(code, 255)
        XCTAssertNil(out)
        XCTAssertTrue(err?.contains("ssh to brewserver failed") == true)
        XCTAssertTrue(err?.contains("Permission denied (publickey).") == true)
    }

    func testConnectResultMessageGenericFailure() {
        let (out, err, code) = Serve.connectResultMessage(
            code: 7, sshHost: "brewserver", url: "http://1.2.3.4:3456/mcp",
            childOut: "", childErr: "something else")
        XCTAssertEqual(code, 7)
        XCTAssertNil(out)
        XCTAssertTrue(err?.contains("connect failed on brewserver (exit 7)") == true)
        XCTAssertTrue(err?.contains("something else") == true)
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
