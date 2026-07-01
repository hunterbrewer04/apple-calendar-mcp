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
