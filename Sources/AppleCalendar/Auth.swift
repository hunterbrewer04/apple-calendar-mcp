import Foundation
import CryptoKit

enum StartupError: Error, Equatable { case missingToken }

struct ServerConfig {
    let host: String
    let port: Int
    /// Startup snapshot of every valid token → client name. The HTTP handler re-reads live
    /// through TokenCache; this snapshot exists for the fail-closed startup check.
    let tokens: [String: String]
    let allowNoAuth: Bool
    /// Kept so HTTPRunner can rebuild the live token loader for the same home.
    let homeDir: String

    /// Open (no auth at all) only when --no-auth was passed AND no env token exists.
    /// Decided once at startup: a token appearing later tightens auth; nothing can loosen it.
    var isOpen: Bool { allowNoAuth && tokens.isEmpty }

    static func fromEnvironment(
        _ env: [String: String],
        argv: [String],
        readFile: (String) -> String? = ServerConfig.readTokenFile,
        homeDir: String = NSHomeDirectory(),
        listDir: (String) -> [String] = TokenStore.listTokenFiles
    ) -> ServerConfig {
        func argValue(_ flag: String) -> String? {
            guard let idx = argv.firstIndex(of: flag), argv.index(after: idx) < argv.endIndex else { return nil }
            return argv[argv.index(after: idx)]
        }
        let allowNoAuth = argv.contains("--no-auth")
        return ServerConfig(
            host: argValue("--host") ?? env["CALENDAR_MCP_HOST"] ?? "127.0.0.1",
            port: argValue("--port").flatMap(Int.init) ?? Int(env["CALENDAR_MCP_PORT"] ?? "") ?? 3456,
            tokens: TokenStore.load(env: env, homeDir: homeDir, allowNoAuth: allowNoAuth,
                                    readFile: readFile, listDir: listDir),
            allowNoAuth: allowNoAuth,
            homeDir: homeDir)
    }

    /// Default token-file reader: returns file contents, or nil if unreadable/missing.
    static func readTokenFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    func validate() throws {
        if tokens.isEmpty && !allowNoAuth { throw StartupError.missingToken }
    }
}

enum Auth {
    /// The matched client name, or nil when unauthorized. `open` (validated --no-auth with
    /// no env token) admits every request as "anonymous". An empty token set with
    /// open == false denies everything — revoking the last token fails closed.
    static func authorize(header: String?, tokens: [String: String], open: Bool) -> String? {
        if open { return "anonymous" }
        guard let header else { return nil }
        // Compare fixed-length SHA-256 digests per candidate: both sides are always 32
        // bytes, so neither the result nor the comparison timing leaks token length. The
        // XOR fold is the constant-time equality test over those 32 bytes. (Which entry
        // matched is observable via timing; token *contents* are not.)
        let presented = Array(SHA256.hash(data: Data(header.utf8)))
        for (token, client) in tokens {
            let expected = Array(SHA256.hash(data: Data("Bearer \(token)".utf8)))
            var diff: UInt8 = 0
            for i in 0..<presented.count { diff |= presented[i] ^ expected[i] }
            if diff == 0 { return client }
        }
        return nil
    }
}
