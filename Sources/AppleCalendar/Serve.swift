import Foundation

enum Serve {
    static let label = "com.apple-calendar-mcp"
    static let defaultPort = 3456
    // Homebrew's stable `opt` symlink for the installed binary, checked for both
    // Apple-Silicon (/opt/homebrew) and Intel (/usr/local) prefixes so the LaunchAgent
    // points at a path that survives `brew upgrade` on either architecture.
    static let optBinaryPaths = [
        "/opt/homebrew/opt/apple-calendar/bin/ical",   // Apple Silicon Homebrew
        "/usr/local/opt/apple-calendar/bin/ical",      // Intel Homebrew
    ]

    // MARK: - Paths
    static func configDir(home: String) -> String { "\(home)/.config/apple-calendar" }
    static func tokenPath(home: String) -> String { "\(configDir(home: home))/token" }
    static func plistPath(home: String) -> String { "\(home)/Library/LaunchAgents/\(label).plist" }
    static func logPath(home: String) -> String { "\(home)/Library/Logs/apple-calendar.log" }

    // MARK: - Rendering
    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // Escape a value for embedding inside a JSON string literal. Tokens this tool emits are
    // hex, but a hand-written token file (or an odd --host) could contain quotes/backslashes/
    // control chars; without escaping, the pasted client config would be invalid JSON.
    static func jsonEscape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    // Wrap a value in POSIX single quotes so the shell treats it literally — no $VAR/backtick
    // expansion, no word-splitting. An embedded single quote is closed, escaped, and reopened
    // (`'\''`), which is the standard safe encoding. This turns the copy/paste command from a
    // shell-injection footgun into a value the shell passes through verbatim.
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func plistXML(binaryPath: String, host: String, port: Int, logPath: String) -> String {
        let args = [binaryPath, "mcp", "--http", "--host", host, "--port", String(port)]
        let argXML = args.map { "        <string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(xmlEscape(label))</string>
            <key>ProgramArguments</key>
            <array>
        \(argXML)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(logPath))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(logPath))</string>
        </dict>
        </plist>
        """
    }

    static func clientConfigJSON(host: String, port: Int, token: String) -> String {
        let h = jsonEscape(host); let t = jsonEscape(token)
        return """
        {
          "mcpServers": {
            "apple-calendar": {
              "type": "http",
              "url": "http://\(h):\(port)/mcp",
              "headers": { "Authorization": "Bearer \(t)" }
            }
          }
        }
        """
    }

    static func claudeMcpAddCommand(host: String, port: Int, token: String) -> String {
        "claude mcp add --transport http --scope user apple-calendar "
        + "\(shellSingleQuote("http://\(host):\(port)/mcp")) "
        + "--header \(shellSingleQuote("Authorization: Bearer \(token)"))"
    }

    // The script `serve connect` runs on the remote box to register this Mac's server with the
    // remote Claude Code. The URL and Authorization header are single-quoted so a hostile/odd
    // token can't inject shell. Distinct exit codes (40/41) let the caller map failures to
    // actionable messages: 40 = no claude CLI on the remote, 41 = remote can't reach the server.
    static func remoteConnectScript(host: String, port: Int, token: String) -> String {
        let url = shellSingleQuote("http://\(host):\(port)/mcp")
        let auth = shellSingleQuote("Authorization: Bearer \(token)")
        return """
        set -e
        command -v claude >/dev/null 2>&1 || { echo 'claude CLI not found on this host (login-shell PATH)' >&2; exit 40; }
        claude mcp remove --scope user apple-calendar >/dev/null 2>&1 || true
        claude mcp add --transport http --scope user apple-calendar \(url) --header \(auth)
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \(url) -H 'Accept: application/json, text/event-stream' -d '{}')
        [ "$code" = "401" ] || { echo "probe from this host returned ${code:-none} (expected 401)" >&2; exit 41; }
        echo connected
        """
    }

    // argv for `/usr/bin/ssh` to run `script` on `sshHost`. The `bash -lc` + outer
    // shellSingleQuote is load-bearing: ssh joins the trailing args with spaces and the REMOTE
    // shell re-parses them, so the whole script must arrive as ONE single-quoted argument or its
    // own quoting would be re-split. A login shell (`-l`) is required because `claude` is often at
    // ~/.local/bin, which only a login shell's PATH includes. BatchMode fails fast instead of
    // hanging on a password prompt; ConnectTimeout bounds an unreachable host.
    static func sshConnectArgs(sshHost: String, script: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", sshHost, "bash", "-lc", shellSingleQuote(script)]
    }

    // MARK: - connect args
    struct ConnectArgs: Equatable { var sshHost: String; var printOnly: Bool }
    enum ConnectParseError: Error, Equatable {
        case missingHost; case unknownFlag(String); case unexpectedArg(String); case invalidHost(String)
    }

    /// Parse the args after `serve connect`: one required ssh-host positional and an optional
    /// `--print` flag (accepted in any position). Pure so it's testable without I/O.
    static func parseConnectArgs(_ args: [String]) -> Result<ConnectArgs, ConnectParseError> {
        var host: String?
        var printOnly = false
        for a in args {
            if a == "--print" { printOnly = true }
            else if a.hasPrefix("--") { return .failure(.unknownFlag(a)) }
            // A host starting with '-' is rejected here: OpenSSH has no `--` terminator, so a value
            // like `-oProxyCommand=...` would be parsed as an ssh option and execute an arbitrary
            // LOCAL command. The single-dash guard (not just `--`) is the fix and must stay.
            else if a.hasPrefix("-") { return .failure(.invalidHost(a)) }
            else if host == nil { host = a }
            else { return .failure(.unexpectedArg(a)) }
        }
        guard let host else { return .failure(.missingHost) }
        return .success(ConnectArgs(sshHost: host, printOnly: printOnly))
    }

    // MARK: - Resolution
    enum ServeError: Error, Equatable { case tailscaleUnavailable; case conflictingHostFlags }

    static func resolveHost(explicitHost: String?, useTailscale: Bool, useLocal: Bool,
                            tailscaleIP: () -> String?) -> Result<String, ServeError> {
        let picks = [explicitHost != nil, useTailscale, useLocal].filter { $0 }.count
        if picks > 1 { return .failure(.conflictingHostFlags) }
        if let h = explicitHost { return .success(h) }
        if useLocal { return .success("127.0.0.1") }
        if useTailscale {
            let ip = tailscaleIP()?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ip, !ip.isEmpty else { return .failure(.tailscaleUnavailable) }
            return .success(ip)
        }
        return .success("127.0.0.1")   // secure-by-default
    }

    // Turn argv[0] into an absolute path. When `ical` is run from $PATH, argv[0] is the bare
    // name "ical" (the shell doesn't rewrite it to the resolved path); a relative invocation
    // like `.build/release/apple-calendar` is relative to cwd. launchd does NO $PATH lookup and
    // requires an absolute executable in ProgramArguments[0], so we resolve it here. Returns nil
    // if a bare name can't be found on $PATH.
    static func absolutize(_ argv0: String, cwd: String, pathEnv: String?,
                           fileExists: (String) -> Bool) -> String? {
        if argv0.hasPrefix("/") { return argv0 }
        if argv0.contains("/") {   // relative path → resolve against cwd (lexically, resolves ./ and ../)
            return URL(fileURLWithPath: cwd).appendingPathComponent(argv0).standardized.path
        }
        for dir in (pathEnv ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init) {
            let base = dir.hasPrefix("/") ? dir : URL(fileURLWithPath: cwd).appendingPathComponent(dir).standardized.path
            let candidate = "\(base)/\(argv0)"
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    static func resolveBinaryPath(argv0: String, fileExists: (String) -> Bool,
                                  cwd: String = FileManager.default.currentDirectoryPath,
                                  pathEnv: String? = ProcessInfo.processInfo.environment["PATH"])
    -> (path: String, warning: String?) {
        if let opt = optBinaryPaths.first(where: fileExists) { return (opt, nil) }
        let resolved = absolutize(argv0, cwd: cwd, pathEnv: pathEnv, fileExists: fileExists) ?? argv0
        if resolved.contains("/.build/") {
            return (resolved, "warning: pointing the service at a source build (\(resolved)); "
                         + "install via Homebrew so upgrades don't dangle this path.")
        }
        // A non-absolute path here means we couldn't resolve argv0 (bare name not on $PATH):
        // launchd would silently fail to start the agent, so warn instead of reporting success.
        if !resolved.hasPrefix("/") {
            return (resolved, "warning: could not resolve an absolute path for '\(argv0)'; "
                         + "the LaunchAgent needs one and may fail to start. Install via Homebrew, "
                         + "or run setup using an absolute path to the binary.")
        }
        return (resolved, nil)
    }

    // MARK: - Token
    static func generateToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension Serve {
    /// Minimal process runner. Returns (exitCode, stdout, stderr).
    @discardableResult
    static func shell(_ launchPath: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return (127, "", "\(error)") }
        // Drain stderr on a background thread while reading stdout on this one, so a child
        // that writes more than the OS pipe buffer to either stream can't block on write
        // while we block in waitUntilExit() (the classic Foundation.Process deadlock).
        final class DataBox: @unchecked Sendable { var data = Data() }
        let errBox = DataBox()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errBox.data, encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    /// `/usr/bin/env tailscale ip -4`, first line, or nil.
    static func tailscaleIP() -> String? {
        let r = shell("/usr/bin/env", ["tailscale", "ip", "-4"])
        guard r.code == 0 else { return nil }
        return r.out.split(separator: "\n").first.map(String.init)
    }

    /// Probe the server's /mcp endpoint and describe the result. A `401` is the
    /// "up + auth enforced" signal (the server rejects the unauthenticated probe);
    /// any other HTTP code still means it's responding. A curl launch failure is
    /// reported distinctly so callers never conflate "probe couldn't run" with "down".
    static func livenessLine(host: String, port: Int) -> String {
        let r = shell("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}",
                                        "--max-time", "3", "-X", "POST", "http://\(host):\(port)/mcp",
                                        "-H", "Accept: application/json, text/event-stream", "-d", "{}"])
        if r.code == 127 { return "could not run probe (curl unavailable at /usr/bin/curl)" }
        switch r.out.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "401":     return "up (401 — auth enforced ✓)"
        case "", "000": return "down (connection refused / no response)"
        case let http:  return "up (HTTP \(http))"
        }
    }

    /// True iff a `livenessLine` reports the server is actually responding.
    static func isUp(_ line: String) -> Bool { line.hasPrefix("up") }

    static func run(_ argv: [String]) -> (stdout: String?, stderr: String?, exitCode: Int32) {
        let home = NSHomeDirectory()
        let sub = argv.first ?? ""
        let rest = Array(argv.dropFirst())
        switch sub {
        case "setup":     return setup(rest, home: home)
        case "status":    return status(home: home)
        case "connect":   return connect(rest, home: home)
        case "uninstall": return uninstall(rest, home: home)
        case "token":     return token(home: home)
        default:
            return (nil, """
            Usage: ical serve setup [--host IP | --tailscale | --local] [--port N] [--force]
                   ical serve status
                   ical serve connect <ssh-host> [--print]
                   ical serve uninstall [--purge]
                   ical serve token
            """, 1)
        }
    }

    static func setup(_ args: [String], home: String) -> (String?, String?, Int32) {
        func flagValue(_ f: String) -> String? {
            guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let explicitHost = flagValue("--host")
        let useTailscale = args.contains("--tailscale")
        let useLocal = args.contains("--local")
        let force = args.contains("--force")
        let port = flagValue("--port").flatMap(Int.init) ?? defaultPort

        // Resolve host.
        let host: String
        switch resolveHost(explicitHost: explicitHost, useTailscale: useTailscale, useLocal: useLocal, tailscaleIP: tailscaleIP) {
        case .success(let h): host = h
        case .failure(.tailscaleUnavailable):
            return (nil, "Could not get a Tailscale IP (`tailscale ip -4`). Is Tailscale installed and up? Or pass --host <ip>.", 1)
        case .failure(.conflictingHostFlags):
            return (nil, "Pass only one of --host / --tailscale / --local.", 1)
        }

        // Ensure config dir (0700) + token file (0600).
        let fm = FileManager.default
        let dir = configDir(home: home)
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { return (nil, "Could not create \(dir): \(error.localizedDescription)", 1) }

        let tokPath = tokenPath(home: home)
        let existing = ServerConfig.readTokenFile(tokPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tok: String
        if let existing, !existing.isEmpty, !force {
            tok = existing
        } else {
            tok = generateToken()
            do {
                try tok.write(toFile: tokPath, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokPath)
            } catch { return (nil, "Could not write token to \(tokPath): \(error.localizedDescription)", 1) }
        }

        // Resolve binary + render plist.
        let (bin, binWarn) = resolveBinaryPath(argv0: CommandLine.arguments[0], fileExists: fm.fileExists(atPath:))
        let plist = plistXML(binaryPath: bin, host: host, port: port, logPath: logPath(home: home))
        let plistFile = plistPath(home: home)
        do {
            try fm.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
            try plist.write(toFile: plistFile, atomically: true, encoding: .utf8)
        } catch { return (nil, "Could not write \(plistFile): \(error.localizedDescription)", 1) }

        // (Re)load the agent: bootout (ignore failure) then bootstrap + kickstart.
        let uid = getuid()
        _ = shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        let boot = shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistFile])
        if boot.code != 0 {
            return (nil, "launchctl bootstrap failed: \(boot.err)\nPlist written to \(plistFile).", 1)
        }
        let kick = shell("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(label)"])

        // bootstrap/kickstart returning 0 only means the job LOADED, not that the server
        // bound its port — so probe it (retrying briefly while launchd spawns the process)
        // rather than blindly reporting success for a server that never came up.
        var liveness = livenessLine(host: host, port: port)
        var attempts = 0
        while !isUp(liveness) && attempts < 8 {
            Thread.sleep(forTimeInterval: 0.25); attempts += 1
            liveness = livenessLine(host: host, port: port)
        }
        let started = kick.code == 0 && isUp(liveness)

        // Compose output.
        var out = ""
        if let binWarn { out += "\(binWarn)\n\n" }
        if started {
            out += "✓ apple-calendar server installed and started (\(host):\(port)).\n"
        } else {
            out += "⚠️  apple-calendar server installed but did NOT come up (\(host):\(port)).\n"
            out += "    Liveness: \(liveness)"
            if kick.code != 0 { out += "; launchctl kickstart exited \(kick.code): \(kick.err.trimmingCharacters(in: .whitespacesAndNewlines))" }
            out += "\n    Check `ical serve status` and the log at \(logPath(home: home)).\n"
        }
        out += "  Token file: \(tokPath)\n"
        out += "  LaunchAgent: \(plistFile)  (survives reboot + brew upgrade)\n"
        if host == "127.0.0.1" {
            out += "  Bound to loopback — reachable only on this Mac. For another device rerun with --tailscale or --host <ip>.\n"
        }
        // Warn about other agents that could race for the same port: the maintainer's old
        // personal LaunchAgent, or a `brew services` instance from the previously documented
        // flow. (setup only ever manages its own `\(label)` label.)
        for other in ["com.hunterbrewer.apple-calendar-mcp", "homebrew.mxcl.apple-calendar"]
        where shell("/bin/launchctl", ["print", "gui/\(uid)/\(other)"]).code == 0 {
            out += "\n⚠️  Another agent (\(other)) is still loaded and may fight for port \(port).\n"
            out += other.hasPrefix("homebrew.")
                ? "   Stop it: brew services stop apple-calendar\n"
                : "   Remove it: launchctl bootout gui/\(uid)/\(other) && rm ~/Library/LaunchAgents/\(other).plist\n"
        }
        out += "\nClient config (paste on the other machine):\n\n\(clientConfigJSON(host: host, port: port, token: tok))\n"
        out += "\nOr with Claude Code:\n\n\(claudeMcpAddCommand(host: host, port: port, token: tok))\n"
        return (out, nil, started ? 0 : 1)
    }

    static func status(home: String) -> (String?, String?, Int32) {
        let uid = getuid()
        let plistFile = plistPath(home: home)
        let installed = FileManager.default.fileExists(atPath: plistFile)
        let printOut = shell("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
        let loaded = printOut.code == 0
        var out = "LaunchAgent: \(installed ? "installed (\(plistFile))" : "not installed")\n"
        out += "Loaded: \(loaded ? "yes" : "no")\n"
        if loaded, let pidLine = printOut.out.split(separator: "\n").first(where: { $0.contains("pid = ") }) {
            out += "  \(pidLine.trimmingCharacters(in: .whitespaces))\n"
        }
        let tokPath = tokenPath(home: home)
        let token = ServerConfig.readTokenFile(tokPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasToken = (token?.isEmpty == false)
        out += "Token file: \(hasToken ? "present (\(tokPath))" : "missing")\n"
        // Liveness probe against the *configured* address parsed back out of the plist.
        if let host = plistHost(plistFile: plistFile), let port = plistPort(plistFile: plistFile) {
            out += "Liveness (\(host):\(port)): \(livenessLine(host: host, port: port))\n"
            if let token, !token.isEmpty {
                out += "\nClient config:\n\n\(clientConfigJSON(host: host, port: port, token: token))\n"
            }
        } else if installed {
            out += "Liveness: could not read --host/--port from \(plistFile) (unexpected plist format).\n"
        }
        return (out, nil, 0)
    }

    /// `ical serve connect <ssh-host> [--print]` — from this Mac (running the server), point a
    /// remote box's Claude Code at this server over Tailscale. Reads the installed config, refuses
    /// to hand out a loopback-only or dead server, then either prints the paste-able command
    /// (`--print`) or ssh's in and runs the registration + a 401 reachability probe.
    static func connect(_ args: [String], home: String) -> (String?, String?, Int32) {
        let usage = "Usage: ical serve connect <ssh-host> [--print]"
        let parsed: ConnectArgs
        switch parseConnectArgs(args) {
        case .success(let c): parsed = c
        case .failure(.missingHost):        return (nil, usage, 1)
        case .failure(.unknownFlag(let f)): return (nil, "Unknown flag '\(f)'.\n\(usage)", 1)
        case .failure(.unexpectedArg(let a)): return (nil, "Unexpected argument '\(a)'.\n\(usage)", 1)
        case .failure(.invalidHost(let h)): return (nil, "ssh host may not begin with '-' (got '\(h)').\n\(usage)", 1)
        }

        // Resolve the configured address from the installed plist and the token from disk.
        let plistFile = plistPath(home: home)
        guard let host = plistHost(plistFile: plistFile), let port = plistPort(plistFile: plistFile) else {
            return (nil, "Could not read the installed server config from \(plistFile). Run `ical serve setup --tailscale` first.", 1)
        }
        guard let token = ServerConfig.readTokenFile(tokenPath(home: home))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return (nil, "No auth token found at \(tokenPath(home: home)). Run `ical serve setup --tailscale` first.", 1)
        }
        // A loopback-only server is unreachable from any other host.
        if host == "127.0.0.1" {
            return (nil, "The server is bound to loopback (127.0.0.1) and is unreachable from another host. Rerun `ical serve setup --tailscale`.", 1)
        }
        // Never hand a dead server to a client.
        let liveness = livenessLine(host: host, port: port)
        guard isUp(liveness) else {
            return (nil, "Server is not up at \(host):\(port): \(liveness)\nStart it and check `ical serve status` before connecting a client.", 1)
        }

        let url = "http://\(host):\(port)/mcp"
        if parsed.printOnly {
            return (claudeMcpAddCommand(host: host, port: port, token: token), nil, 0)
        }

        let r = shell("/usr/bin/ssh", sshConnectArgs(sshHost: parsed.sshHost,
                                                     script: remoteConnectScript(host: host, port: port, token: token)))
        return connectResultMessage(code: r.code, sshHost: parsed.sshHost, url: url, childOut: r.out, childErr: r.err)
    }

    /// Map the ssh child's exit code to a user-facing result. Pure so each branch is unit-testable
    /// without spawning ssh. The exit codes come from `remoteConnectScript` (40/41) or ssh itself.
    static func connectResultMessage(code: Int32, sshHost: String, url: String,
                                     childOut: String, childErr: String) -> (String?, String?, Int32) {
        let err = childErr.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = childOut.trimmingCharacters(in: .whitespacesAndNewlines)
        let errTail = err.isEmpty ? "" : "\n\(err)"
        switch code {
        case 0:
            var msg = "✓ Connected \(sshHost) to the apple-calendar MCP server at \(url).\n"
            msg += "  Registered user-scope for Claude Code on \(sshHost) (claude mcp add --scope user apple-calendar).\n"
            if !out.isEmpty { msg += "  Remote: \(out)\n" }
            return (msg, nil, 0)
        case 40:
            return (nil, "The claude CLI was not found on \(sshHost). Install Claude Code there, then rerun." + errTail, 40)
        case 41:
            // Empty $code also fails the 401 check, so a remote box that merely lacks curl lands here too.
            return (nil, "\(sshHost) could not reach the server over the tailnet at \(url) "
                       + "(or curl is not installed there)." + errTail, 41)
        case 255:
            // ssh returns 255 both for its OWN transport/auth failures AND when it propagates a remote
            // command that itself exited 255 — so this diagnosis can be wrong in that rare collision.
            return (nil, "ssh to \(sshHost) failed. Ensure key auth works and that `ssh \(sshHost)` connects non-interactively." + errTail, 255)
        default:
            return (nil, "connect failed on \(sshHost) (exit \(code))." + errTail, code)
        }
    }

    /// Read the --host / --port back out of the installed plist for status/probe.
    static func plistHost(plistFile: String) -> String? { plistArgAfter("--host", plistFile: plistFile) }
    static func plistPort(plistFile: String) -> Int? { plistArgAfter("--port", plistFile: plistFile).flatMap(Int.init) }
    private static func plistArgAfter(_ flag: String, plistFile: String) -> String? {
        guard let xml = try? String(contentsOfFile: plistFile, encoding: .utf8) else { return nil }
        let lines = xml.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let needle = "<string>\(flag)</string>"
        guard let i = lines.firstIndex(of: needle), i + 1 < lines.count else { return nil }
        let next = lines[i + 1]
        guard next.hasPrefix("<string>"), next.hasSuffix("</string>") else { return nil }
        return String(next.dropFirst("<string>".count).dropLast("</string>".count))
    }

    static func uninstall(_ args: [String], home: String) -> (String?, String?, Int32) {
        let uid = getuid()
        let fm = FileManager.default
        _ = shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])   // ignore "not loaded"
        let plistFile = plistPath(home: home)
        var problems: [String] = []
        // A leftover plist reloads at next login (RunAtLoad=true), resurrecting the agent
        // the user believes is gone — a failed delete must be surfaced, not swallowed.
        if fm.fileExists(atPath: plistFile) {
            do { try fm.removeItem(atPath: plistFile) }
            catch { problems.append("could not remove \(plistFile): \(error.localizedDescription) — it will reload at next login until deleted") }
        }
        var out = "✓ Stopped and removed \(label).\n"
        if args.contains("--purge") {
            let dir = configDir(home: home)
            if fm.fileExists(atPath: dir) {
                // --purge is the credential-revocation path: if the token can't be deleted,
                // do NOT claim it's gone (it may still authorize clients).
                do { try fm.removeItem(atPath: dir) }
                catch { problems.append("could not delete \(dir): \(error.localizedDescription) — the token may still be usable; remove it manually") }
            }
            if problems.isEmpty { out += "  Purged \(dir) (token deleted).\n" }
        } else {
            out += "  Token kept at \(tokenPath(home: home)) (use --purge to delete it too).\n"
        }
        if problems.isEmpty { return (out, nil, 0) }
        return (out, "uninstall incomplete:\n  - " + problems.joined(separator: "\n  - "), 1)
    }

    static func token(home: String) -> (String?, String?, Int32) {
        guard let t = ServerConfig.readTokenFile(tokenPath(home: home))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else {
            return (nil, "No token yet. Run `ical serve setup` first.", 1)
        }
        return (t, nil, 0)   // pipe to pbcopy: `ical serve token | pbcopy`
    }
}
