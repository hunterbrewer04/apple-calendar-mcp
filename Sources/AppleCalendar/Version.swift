/// The release version this binary reports (MCP `serverInfo.version`).
///
/// There is no other single source of truth: Package.swift carries no version and the
/// Homebrew formula builds from a git tag. Bump this in the same commit that gets tagged
/// `vX.Y.Z` so the running server and the installed formula agree.
enum AppVersion {
    static let current = "1.4.2"
}
