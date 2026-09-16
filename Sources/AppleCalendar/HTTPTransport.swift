import Foundation
import HTTPTypes
import Hummingbird
import MCP
import NIOCore

enum HTTPRunner {
    static func run(store: CalendarStore, config: ServerConfig) async throws {
        // One MCP Server + transport *per session*, not one shared instance.
        //
        // The SDK's StatefulHTTPServerTransport (and the Server it drives) are
        // single-session and one-shot: the first `initialize` binds the transport's
        // session id, and a client `DELETE` terminates the transport permanently.
        // A single process-wide instance therefore stops accepting new clients as
        // soon as the first one disconnects (which Claude Code does on shutdown),
        // surfacing as "Session already initialized" on every later connect. This
        // manager mirrors the SDK's reference `HTTPApp`: each `initialize` mints a
        // fresh session, later requests route by `MCP-Session-Id`, and sessions are
        // torn down on `DELETE` or evicted least-recently-used once the table is full.
        let app = makeApplication(config: config, sessions: SessionManager(store: store))
        try await app.runService()
    }

    /// Builds the HTTP application without running it.
    ///
    /// `run` blocks forever inside `runService`, which is what production wants but
    /// leaves nothing for a test to hold on to. Tests call this with `config.port == 0`,
    /// read the bound port back from `onServerRunning`, drive real HTTP against it, and
    /// stop the server by cancelling the task that awaits `app.run()`.
    static func makeApplication(
        config: ServerConfig,
        sessions: SessionManager,
        onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in }
    ) -> some ApplicationProtocol {
        // Live token view: `serve token add`/`revoke` on this Mac take effect within the
        // TTL without restarting the server (which would drop every client's session).
        // Under --no-auth files are never consulted, so the cache serves the startup
        // snapshot (env-only) forever.
        let env = ProcessInfo.processInfo.environment
        let tokenCache = TokenCache { [tokens = config.tokens, allowNoAuth = config.allowNoAuth, home = config.homeDir] in
            allowNoAuth ? tokens : TokenStore.load(env: env, homeDir: home, allowNoAuth: false)
        }

        // Build a Hummingbird router that bridges HTTP requests to the SDK transport.
        let router = Router()

        // Shared handler for POST, GET, and DELETE on /mcp.
        @Sendable func mcpHandler(request: Hummingbird.Request, context: some Hummingbird.RequestContext) async throws -> Hummingbird.Response {
            // --- Auth gate ---
            let authHeader = request.headers[.authorization]
            guard let client = Auth.authorize(header: authHeader,
                                              tokens: await tokenCache.current(),
                                              open: config.isOpen) else {
                return Hummingbird.Response(
                    status: .unauthorized,
                    headers: [.contentType: "text/plain", .wwwAuthenticate: "Bearer"],
                    body: ResponseBody(byteBuffer: ByteBuffer(string: "Unauthorized\n"))
                )
            }

            // --- Collect body ---
            let bodyData: Data?
            if request.method == .post {
                let buf = try await request.body.collect(upTo: 10 * 1024 * 1024)  // 10 MB limit
                bodyData = buf.readableBytes > 0 ? Data(buffer: buf) : nil
            } else {
                bodyData = nil
            }

            // --- Build SDK HTTPRequest ---
            // Convert Hummingbird's HTTPFields into [String: String] for the SDK.
            var headerDict: [String: String] = [:]
            for field in request.headers {
                headerDict[field.name.rawName] = field.value
            }
            let sdkRequest = MCP.HTTPRequest(
                method: request.method.rawValue,
                headers: headerDict,
                body: bodyData,
                path: "/mcp"
            )

            // --- Dispatch through the per-session manager ---
            let sdkResponse = await sessions.handle(sdkRequest, client: client)

            // --- Convert SDK response to Hummingbird response ---
            return buildHummingbirdResponse(from: sdkResponse)
        }

        router.post("/mcp", use: mcpHandler)
        router.get("/mcp", use: mcpHandler)
        router.on("/mcp", method: .delete, use: mcpHandler)

        return Application(
            router: router,
            configuration: ApplicationConfiguration(
                address: .hostname(config.host, port: config.port)
            ),
            onServerRunning: onServerRunning
        )
    }

    // MARK: - Response conversion

    private static func buildHummingbirdResponse(from sdkResponse: MCP.HTTPResponse) -> Hummingbird.Response {
        switch sdkResponse {
        case .stream(let asyncStream, _):
            // SSE streaming body: pipe each Data chunk from the AsyncThrowingStream.
            let headers = httpFields(from: sdkResponse.headers)
            let body = ResponseBody { writer in
                for try await chunk in asyncStream {
                    try await writer.write(ByteBuffer(bytes: chunk))
                }
                try await writer.finish(nil)
            }
            return Hummingbird.Response(status: .ok, headers: headers, body: body)

        default:
            let status = HTTPTypes.HTTPResponse.Status(code: sdkResponse.statusCode)
            let headers = httpFields(from: sdkResponse.headers)
            if let data = sdkResponse.bodyData {
                return Hummingbird.Response(
                    status: status,
                    headers: headers,
                    body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
                )
            } else {
                return Hummingbird.Response(status: status, headers: headers, body: ResponseBody())
            }
        }
    }

    // Convert [String: String] → HTTPFields (Hummingbird's header collection).
    private static func httpFields(from dict: [String: String]) -> HTTPFields {
        var fields = HTTPFields()
        for (key, value) in dict {
            if let name = HTTPField.Name(key) {
                fields.append(HTTPField(name: name, value: value))
            }
        }
        return fields
    }
}

// MARK: - Per-session management

/// Owns one `Server` + `StatefulHTTPServerTransport` per MCP session id.
///
/// See the note in `HTTPRunner.run` for *why* this exists. In short: the SDK
/// transports are single-session and one-shot, so a long-lived server that
/// different clients (and reconnects) hit over time must create a fresh
/// server/transport per `initialize` and route subsequent requests by their
/// `MCP-Session-Id` — exactly what the SDK's reference `HTTPApp` does.
///
/// Unlike the reference `HTTPApp`, there is deliberately NO background reaper task.
/// The reference's 60 s `Task.sleep` cleanup loop aborted this process on its first
/// wake under reconnect churn (`swift_task_dealloc` "freed pointer was not the last
/// allocation" out of the reaper closure; reproduced 2026-09-16 at 57 sessions / 58 s)
/// in release builds from the Swift 6.2 toolchain, and launchd's KeepAlive hid the
/// once-a-minute crash loop for two months. The same source built with Swift 6.4 ran
/// the same churn without aborting, which points at the older toolchain's codegen
/// rather than this code — but the formula builds from source with whatever toolchain
/// the host has, so the pattern is removed rather than relied on. The table is
/// bounded inline instead: when an `initialize` would push it past `maxSessions`, the
/// least-recently-used sessions are closed on the request path. Abandoned sessions
/// (clients that reconnect without a `DELETE`) are exactly the ones that go stale, so
/// LRU is the right victim order.
actor SessionManager {
    /// Default cap on live sessions. Each client holds one session, so a handful of
    /// machines sit far below this; it only bites under reconnect churn, where it
    /// replaces what the idle reaper was meant to do.
    static let defaultMaxSessions = 256

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        /// Which credential opened the session; carried so eviction lines attribute too.
        let client: String
        /// Monotonic access ordinal, not a wall-clock time, so LRU order is exact and
        /// immune to clock adjustments.
        var lastAccessed: UInt64
    }

    private let store: CalendarStore
    private let validationPipeline: any HTTPRequestValidationPipeline
    private let maxSessions: Int
    private var sessions: [String: Session] = [:]
    private var accessCounter: UInt64 = 0

    init(store: CalendarStore, maxSessions: Int = SessionManager.defaultMaxSessions) {
        precondition(maxSessions > 0, "maxSessions must allow at least one live session")
        self.store = store
        self.maxSessions = maxSessions
        // Origin validation is disabled so remote tailnet clients (whose Host header
        // is not localhost) are accepted. The same (stateless) pipeline is shared by
        // every per-session transport.
        self.validationPipeline = StandardValidationPipeline(validators: [
            OriginValidator.disabled,
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])
    }

    /// Number of live sessions. Exposed for tests asserting the cap holds.
    var count: Int { sessions.count }

    func handle(_ request: MCP.HTTPRequest, client: String) async -> MCP.HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Route to an existing session.
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessed = nextAccess()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            // A successful DELETE terminates the session; drop our reference.
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await closeSession(sessionID)
            }
            return response
        }

        // No live session: only an `initialize` POST may create one.
        if request.method.uppercased() == "POST", Self.isInitializeRequest(request.body) {
            return await createSessionAndHandle(request, client: client)
        }

        // No session and not an initialize.
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(statusCode: 400, .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
    }

    private func createSessionAndHandle(_ request: MCP.HTTPRequest, client: String) async -> MCP.HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline
        )
        let server = await makeServer(store: store)

        do {
            try await server.start(transport: transport)
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Failed to start session: \(error.localizedDescription)"))
        }

        // Make room first, then insert in the same actor turn, so the table never
        // holds more than `maxSessions` entries and the new session is never a victim.
        await evictLeastRecentlyUsed(downTo: maxSessions - 1)
        sessions[sessionID] = Session(server: server, transport: transport, client: client, lastAccessed: nextAccess())
        // One line per session (not per request) into the LaunchAgent log, so `ical serve`
        // deployments can tell WHICH machine's credential opened each session.
        FileHandle.standardError.write(Data("session \(sessionID) client=\(client)\n".utf8))

        let response = await transport.handleRequest(request)
        // If the transport rejected the initialize, don't leak the session.
        if case .error = response {
            await closeSession(sessionID)
        }
        return response
    }

    private func nextAccess() -> UInt64 {
        accessCounter &+= 1
        return accessCounter
    }

    /// Closes least-recently-used sessions until at most `limit` remain. Re-reads the
    /// live count after every await: `closeSession` suspends on the transport, and
    /// another `initialize` may have run its own eviction in the meantime.
    private func evictLeastRecentlyUsed(downTo limit: Int) async {
        while sessions.count > limit,
              let victim = sessions.min(by: { $0.value.lastAccessed < $1.value.lastAccessed }) {
            FileHandle.standardError.write(
                Data("session \(victim.key) client=\(victim.value.client) evicted (cap \(maxSessions))\n".utf8))
            await closeSession(victim.key)
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
    }

    /// Detects a JSON-RPC `initialize` request without the SDK's package-private
    /// `JSONRPCMessageKind` (which isn't visible outside the SDK's own package).
    private static func isInitializeRequest(_ body: Data?) -> Bool {
        guard let body,
            let object = try? JSONSerialization.jsonObject(with: body),
            let dict = object as? [String: Any],
            let method = dict["method"] as? String
        else { return false }
        return method == "initialize"
    }
}

/// A `SessionIDGenerator` that always returns a pre-chosen id, so the manager's
/// dictionary key matches the id the transport reports back to the client.
private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}
