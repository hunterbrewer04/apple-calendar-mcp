import Foundation
import CryptoKit

/// Loads the set of valid client tokens from every configured source and owns the
/// client-name rules shared by the server, `serve token`, and `serve connect`.
enum TokenStore {
    static func tokensDir(home: String) -> String { "\(home)/.config/apple-calendar/tokens" }

    /// First char alphanumeric (also excludes dotfiles like .DS_Store from directory
    /// scans), then [A-Za-z0-9._-], max 64 total. Filenames double as client names, so
    /// this is also the path-traversal guard for `token add <name>`.
    static func isValidClientName(_ name: String) -> Bool {
        guard name.count >= 1, name.count <= 64 else { return false }
        guard let first = name.unicodeScalars.first, isAlnum(first) else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy { isAlnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }
    private static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }

    /// Derive a valid client name from an ssh destination: drop any user@ prefix, map
    /// disallowed characters to '-', trim leading non-alphanumerics, cap at 64. Never
    /// returns an invalid name — "client" is the fallback for degenerate input.
    static func clientName(forSSHHost host: String) -> String {
        let bare = host.split(separator: "@").last.map(String.init) ?? host
        var mapped = String(bare.unicodeScalars.map { scalar -> Character in
            (isAlnum(scalar) || scalar == "." || scalar == "_" || scalar == "-") ? Character(scalar) : "-"
        })
        while let f = mapped.unicodeScalars.first, !isAlnum(f) { mapped.removeFirst() }
        let name = String(mapped.prefix(64))
        return isValidClientName(name) ? name : "client"
    }

    /// Non-reversible short identifier for `token list` — safe to print, useless to replay.
    static func fingerprint(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined().prefix(12)
    }

    /// Sorted valid client names in the tokens dir; unreadable/missing dir is just "no clients".
    static func listTokenFiles(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter(isValidClientName).sorted()
    }

    /// Union of every token source → [token: clientName]. Under --no-auth only the env var
    /// is consulted (a leftover file token must not silently re-enable auth — see ServerConfig).
    /// Duplicate token values: last sorted name wins for attribution; auth is unaffected.
    static func load(env: [String: String], homeDir: String, allowNoAuth: Bool,
                     readFile: (String) -> String? = ServerConfig.readTokenFile,
                     listDir: (String) -> [String] = TokenStore.listTokenFiles) -> [String: String] {
        var tokens: [String: String] = [:]
        // Env token: verbatim (not trimmed), whitespace-only counts as absent — exact legacy
        // behavior, or an already-deployed padded credential would break on upgrade.
        if let raw = env["CALENDAR_MCP_TOKEN"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tokens[raw] = "env"
        }
        if allowNoAuth { return tokens }
        func trimmedNonEmpty(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        // Legacy single-token file (an empty CALENDAR_MCP_TOKEN_FILE falls back to the default path).
        let legacyPath = trimmedNonEmpty(env["CALENDAR_MCP_TOKEN_FILE"]) ?? "\(homeDir)/.config/apple-calendar/token"
        if let t = trimmedNonEmpty(readFile(legacyPath)) { tokens[t] = "default" }
        // Per-client token files.
        let dir = tokensDir(home: homeDir)
        for name in listDir(dir) {
            if let t = trimmedNonEmpty(readFile("\(dir)/\(name)")) { tokens[t] = name }
        }
        return tokens
    }
}

/// TTL-cached live view of the token set, so `serve token add`/`revoke` take effect on a
/// running server within `ttl` seconds — no restart, no dropped sessions for other clients.
actor TokenCache {
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let load: @Sendable () -> [String: String]
    private var cached: [String: String] = [:]
    private var loadedAt: Date?

    init(ttl: TimeInterval = 5, now: @escaping @Sendable () -> Date = Date.init,
         load: @escaping @Sendable () -> [String: String]) {
        self.ttl = ttl
        self.now = now
        self.load = load
    }

    func current() -> [String: String] {
        if let loadedAt, now().timeIntervalSince(loadedAt) <= ttl { return cached }
        cached = load()
        loadedAt = now()
        return cached
    }
}
