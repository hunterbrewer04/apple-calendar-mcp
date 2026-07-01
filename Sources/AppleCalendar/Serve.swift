import Foundation

enum Serve {
    static let label = "com.apple-calendar-mcp"
    static let defaultPort = 3456
    static let optBinaryPath = "/opt/homebrew/opt/apple-calendar/bin/ical"

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
        """
        {
          "mcpServers": {
            "apple-calendar": {
              "type": "http",
              "url": "http://\(host):\(port)/mcp",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    static func claudeMcpAddCommand(host: String, port: Int, token: String) -> String {
        "claude mcp add --transport http --scope user apple-calendar "
        + "http://\(host):\(port)/mcp --header \"Authorization: Bearer \(token)\""
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
            guard let ip = tailscaleIP(), !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .failure(.tailscaleUnavailable) }
            return .success(ip.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .success("127.0.0.1")   // secure-by-default
    }

    static func resolveBinaryPath(argv0: String, fileExists: (String) -> Bool) -> (path: String, warning: String?) {
        if fileExists(optBinaryPath) { return (optBinaryPath, nil) }
        if argv0.contains("/.build/") {
            return (argv0, "warning: pointing the service at a source build (\(argv0)); "
                         + "install via Homebrew so upgrades don't dangle this path.")
        }
        return (argv0, nil)
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
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    /// `/usr/bin/env tailscale ip -4`, first line, or nil.
    static func tailscaleIP() -> String? {
        let r = shell("/usr/bin/env", ["tailscale", "ip", "-4"])
        guard r.code == 0 else { return nil }
        return r.out.split(separator: "\n").first.map(String.init)
    }

    static func run(_ argv: [String]) -> (stdout: String?, stderr: String?, exitCode: Int32) {
        let home = NSHomeDirectory()
        let sub = argv.first ?? ""
        let rest = Array(argv.dropFirst())
        switch sub {
        case "setup":     return setup(rest, home: home)
        case "status":    return status(home: home)
        case "uninstall": return uninstall(rest, home: home)
        case "token":     return token(home: home)
        default:
            return (nil, """
            Usage: ical serve setup [--host IP | --tailscale | --local] [--port N] [--force]
                   ical serve status
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
        _ = shell("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(label)"])

        // Compose output.
        var out = ""
        if let binWarn { out += "\(binWarn)\n\n" }
        out += "✓ apple-calendar server installed and started (\(host):\(port)).\n"
        out += "  Token file: \(tokPath)\n"
        out += "  LaunchAgent: \(plistFile)  (survives reboot + brew upgrade)\n"
        if host == "127.0.0.1" {
            out += "  Bound to loopback — reachable only on this Mac. For another device rerun with --tailscale or --host <ip>.\n"
        }
        // Warn if the maintainer's old personal agent is still loaded.
        let legacy = "com.hunterbrewer.apple-calendar-mcp"
        if shell("/bin/launchctl", ["print", "gui/\(uid)/\(legacy)"]).code == 0 {
            out += "\n⚠️  An older agent (\(legacy)) is still loaded and may fight for the port.\n"
            out += "   Remove it: launchctl bootout gui/\(uid)/\(legacy) && rm ~/Library/LaunchAgents/\(legacy).plist\n"
        }
        out += "\nClient config (paste on the other machine):\n\n\(clientConfigJSON(host: host, port: port, token: tok))\n"
        out += "\nOr with Claude Code:\n\n\(claudeMcpAddCommand(host: host, port: port, token: tok))\n"
        return (out, nil, 0)
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
        let hasToken = (ServerConfig.readTokenFile(tokPath)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        out += "Token file: \(hasToken ? "present (\(tokPath))" : "missing")\n"
        // Liveness probe against the *configured* address parsed back out of the plist, if any.
        if let host = plistHost(plistFile: plistFile), let port = plistPort(plistFile: plistFile) {
            let probe = shell("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}",
                                                "-X", "POST", "http://\(host):\(port)/mcp",
                                                "-H", "Accept: application/json, text/event-stream", "-d", "{}"])
            out += "Liveness (\(host):\(port)): \(probe.out == "401" ? "up (401 — auth enforced ✓)" : "code \(probe.out.isEmpty ? "no response" : probe.out)")\n"
            if hasToken, let tok = ServerConfig.readTokenFile(tokPath)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                out += "\nClient config:\n\n\(clientConfigJSON(host: host, port: port, token: tok))\n"
            }
        }
        return (out, nil, 0)
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
        _ = shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        let plistFile = plistPath(home: home)
        try? FileManager.default.removeItem(atPath: plistFile)
        var out = "✓ Stopped and removed \(label).\n"
        if args.contains("--purge") {
            try? FileManager.default.removeItem(atPath: configDir(home: home))
            out += "  Purged \(configDir(home: home)) (token deleted).\n"
        } else {
            out += "  Token kept at \(tokenPath(home: home)) (use --purge to delete it too).\n"
        }
        return (out, nil, 0)
    }

    static func token(home: String) -> (String?, String?, Int32) {
        guard let t = ServerConfig.readTokenFile(tokenPath(home: home))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else {
            return (nil, "No token yet. Run `ical serve setup` first.", 1)
        }
        return (t, nil, 0)   // pipe to pbcopy: `ical serve token | pbcopy`
    }
}
