import Foundation
import CryptoKit

enum StartupError: Error, Equatable { case missingToken }

struct ServerConfig {
    let host: String
    let port: Int
    let token: String?
    let allowNoAuth: Bool

    static func fromEnvironment(
        _ env: [String: String],
        argv: [String],
        readFile: (String) -> String? = ServerConfig.readTokenFile,
        homeDir: String = NSHomeDirectory()
    ) -> ServerConfig {
        func argValue(_ flag: String) -> String? {
            guard let idx = argv.firstIndex(of: flag), argv.index(after: idx) < argv.endIndex else { return nil }
            return argv[argv.index(after: idx)]
        }
        // Trim + empty→nil. Used for file sources (a token file naturally carries a
        // trailing newline) and for the *_FILE path env var.
        func trimmedNonEmpty(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        // The env token keeps its exact legacy behavior: used VERBATIM (not trimmed), but a
        // whitespace-only value counts as absent so it still fails closed. Trimming it would
        // silently change the credential for a deployment whose token has surrounding
        // whitespace, locking out already-configured clients on upgrade.
        func envTokenNonEmpty(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        let allowNoAuth = argv.contains("--no-auth")
        // Precedence: explicit env token → CALENDAR_MCP_TOKEN_FILE → default file. An empty
        // CALENDAR_MCP_TOKEN_FILE (e.g. an unset shell var) falls back to the default path
        // rather than suppressing it. Under `--no-auth` the file is NOT consulted, so a
        // leftover `serve setup` token can't silently re-enable auth and contradict the
        // "running without auth" warning — `--no-auth` yields a genuinely open server.
        let tokenFilePath = trimmedNonEmpty(env["CALENDAR_MCP_TOKEN_FILE"]) ?? "\(homeDir)/.config/apple-calendar/token"
        let token = allowNoAuth
            ? envTokenNonEmpty(env["CALENDAR_MCP_TOKEN"])
            : (envTokenNonEmpty(env["CALENDAR_MCP_TOKEN"]) ?? trimmedNonEmpty(readFile(tokenFilePath)))
        return ServerConfig(
            host: argValue("--host") ?? env["CALENDAR_MCP_HOST"] ?? "127.0.0.1",
            port: argValue("--port").flatMap(Int.init) ?? Int(env["CALENDAR_MCP_PORT"] ?? "") ?? 3456,
            token: token,
            allowNoAuth: allowNoAuth)
    }

    /// Default token-file reader: returns file contents, or nil if unreadable/missing.
    static func readTokenFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    func validate() throws {
        if token == nil && !allowNoAuth { throw StartupError.missingToken }
    }
}

enum Auth {
    /// True iff the request is authorized. When `token` is nil (only reachable via the
    /// validated `--no-auth` path) every request is allowed.
    static func authorize(header: String?, token: String?) -> Bool {
        guard let token else { return true }
        guard let header else { return false }
        // Compare fixed-length SHA-256 digests: both sides are always 32 bytes, so neither
        // the result nor the comparison timing leaks the token's length (a raw count check
        // would). The XOR fold is the constant-time equality test over those 32 bytes.
        let a = Array(SHA256.hash(data: Data(header.utf8)))
        let b = Array(SHA256.hash(data: Data("Bearer \(token)".utf8)))
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
