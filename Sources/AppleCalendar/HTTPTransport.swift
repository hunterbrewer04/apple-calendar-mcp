import Foundation
import HTTPTypes
import Hummingbird
import MCP
import NIOCore

enum HTTPRunner {
    static func run(store: CalendarStore, config: ServerConfig) async throws {
        // Build a custom validation pipeline that disables origin validation so
        // remote tailnet clients (whose Host header is not localhost) are accepted.
        // The same (stateless) pipeline config is reused for every per-session
        // transport.
        let pipeline = StandardValidationPipeline(validators: [
            OriginValidator.disabled,
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])

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
        // torn down on `DELETE` or idle timeout.
        let sessions = SessionManager(store: store, validationPipeline: pipeline)
        await sessions.startReaper()

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

        let app = Application(
            router: router,
            configuration: ApplicationConfiguration(
                address: .hostname(config.host, port: config.port)
            )
        )
        try await app.runService()
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
actor SessionManager {
    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccessed: Date
    }

    private let store: CalendarStore
    private let validationPipeline: any HTTPRequestValidationPipeline
    /// Idle sessions older than this are reaped. Mirrors the SDK default (1h).
    private let idleTimeout: TimeInterval
    private var sessions: [String: Session] = [:]
    private var reaperStarted = false

    init(store: CalendarStore, validationPipeline: any HTTPRequestValidationPipeline, idleTimeout: TimeInterval = 3600) {
        self.store = store
        self.validationPipeline = validationPipeline
        self.idleTimeout = idleTimeout
    }

    func handle(_ request: MCP.HTTPRequest, client: String) async -> MCP.HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Route to an existing session.
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessed = Date()
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

        sessions[sessionID] = Session(server: server, transport: transport, lastAccessed: Date())
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

    // MARK: - Idle-session reaper

    /// Starts the background sweep that closes sessions clients abandoned without
    /// a `DELETE`. Idempotent.
    func startReaper() {
        guard !reaperStarted else { return }
        reaperStarted = true
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await self.reapIdleSessions()
            }
        }
    }

    private func reapIdleSessions() async {
        let now = Date()
        let stale = sessions.filter { now.timeIntervalSince($0.value.lastAccessed) > idleTimeout }
        for (sessionID, _) in stale {
            await closeSession(sessionID)
        }
    }
}

/// A `SessionIDGenerator` that always returns a pre-chosen id, so the manager's
/// dictionary key matches the id the transport reports back to the client.
private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}
