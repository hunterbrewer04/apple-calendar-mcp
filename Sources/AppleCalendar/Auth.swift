import Foundation
import CryptoKit

enum StartupError: Error, Equatable { case missingToken }

struct ServerConfig {
    let host: String
    let port: Int
    let token: String?
    let allowNoAuth: Bool

    static func fromEnvironment(_ env: [String: String], argv: [String]) -> ServerConfig {
        // Parse --host <value> and --port <value> from argv; fall back to env then defaults.
        func argValue(_ flag: String) -> String? {
            guard let idx = argv.firstIndex(of: flag), argv.index(after: idx) < argv.endIndex else { return nil }
            return argv[argv.index(after: idx)]
        }
        // A whitespace-only token counts as "no token" so a user who fat-fingers
        // CALENDAR_MCP_TOKEN="" or " " gets the fail-closed refusal, not a server that
        // silently accepts "Bearer  " as a credential.
        let rawToken = env["CALENDAR_MCP_TOKEN"]
        let token = rawToken.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return ServerConfig(
            host: argValue("--host") ?? env["CALENDAR_MCP_HOST"] ?? "127.0.0.1",
            port: argValue("--port").flatMap(Int.init) ?? Int(env["CALENDAR_MCP_PORT"] ?? "") ?? 3456,
            token: token,
            allowNoAuth: argv.contains("--no-auth"))
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
