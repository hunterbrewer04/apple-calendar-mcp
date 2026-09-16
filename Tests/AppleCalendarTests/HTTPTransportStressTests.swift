import XCTest
import MCP
import NIOCore
@testable import apple_calendar

/// Churns real MCP sessions through the real Hummingbird server over loopback.
///
/// Each cycle is what an abruptly reconnecting client does: `initialize` →
/// `notifications/initialized` → `tools/list` → open the GET SSE stream → drop the
/// connection without a `DELETE`. That is the traffic under which the old background
/// reaper aborted the process (`swift_task_dealloc`, Swift 6.2 release builds) on its
/// first 60 s wake. This test guards the replacement — inline LRU eviction on the
/// request path — by running it hundreds of times in a few seconds and checking the
/// server still answers and the table respected its cap. It would NOT have caught the
/// original bug: that needed 60 s of wall clock and the older toolchain. What it does
/// give is a loud failure mode for the same class of defect: a runtime abort in the
/// session lifecycle kills the test process, which no assertion can miss.
///
/// Run this in release too (`swift test -c release`): the original abort was only ever
/// reproduced in release builds, so a debug-only suite has a blind spot here.
final class HTTPTransportStressTests: XCTestCase {
    /// The historical abort hit at ~55 sessions; 1,000 is ~20x that.
    private static let cycles = 1_000
    /// Small cap so eviction runs hundreds of times, not once.
    private static let maxSessions = 8

    func testSessionChurnDoesNotCrashAndStaysBounded() async throws {
        let sessions = SessionManager(store: MockCalendarStore(), maxSessions: Self.maxSessions)
        // Port 0 → kernel picks an ephemeral port; `onServerRunning` reports it back.
        let config = ServerConfig(host: "127.0.0.1", port: 0, tokens: [:], allowNoAuth: true,
                                  homeDir: NSTemporaryDirectory())
        let (ports, portSink) = AsyncStream<Int>.makeStream()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let app = HTTPRunner.makeApplication(config: config, sessions: sessions) { channel in
                    portSink.yield(channel.localAddress?.port ?? -1)
                }
                // Cancelling this task is how the test stops the server. Finishing the
                // port stream on any exit keeps a failed bind from hanging the test.
                defer { portSink.finish() }
                do {
                    try await app.run()
                } catch {
                    if !Task.isCancelled { throw error }
                }
            }

            var iterator = ports.makeAsyncIterator()
            let reportedPort = await iterator.next()
            let port = try XCTUnwrap(reportedPort, "server exited before reporting its port")
            XCTAssertGreaterThan(port, 0)
            let client = MCPHTTPClient(endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!)

            for cycle in 0..<Self.cycles {
                let session = try await client.initialize()
                try await client.notifyInitialized(session: session)
                let tools = try await client.toolsList(session: session)
                XCTAssertFalse(tools.isEmpty, "cycle \(cycle): tools/list came back empty")
                try await client.openAndDropSSE(session: session)

                let live = await sessions.count
                XCTAssertLessThanOrEqual(live, Self.maxSessions, "cycle \(cycle): session table exceeded cap")
            }

            // Still answering after the churn.
            let session = try await client.initialize()
            try await client.notifyInitialized(session: session)
            let tools = try await client.toolsList(session: session)
            XCTAssertFalse(tools.isEmpty)
            let live = await sessions.count
            XCTAssertLessThanOrEqual(live, Self.maxSessions)
            XCTAssertGreaterThan(live, 0)

            group.cancelAll()
            // Drain so a real server-side error (not cancellation) surfaces as itself
            // instead of as whatever confusing client error it caused first.
            while try await group.next() != nil {}
        }
    }
}

// MARK: - Minimal Streamable-HTTP client

/// Just enough of the MCP Streamable HTTP client to drive the server: JSON-RPC over
/// POST with SSE-framed responses, plus the standalone GET stream.
private struct MCPHTTPClient {
    let endpoint: URL
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private static let initializeBody = Data("""
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"stress","version":"0"}}}
    """.utf8)
    private static let initializedBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
    private static let toolsListBody = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)

    func initialize() async throws -> String {
        let (data, response) = try await post(Self.initializeBody, session: nil)
        guard response.statusCode == 200 else { throw ClientError.status(response.statusCode, "initialize") }
        guard let id = response.value(forHTTPHeaderField: HTTPHeaderName.sessionID) else {
            throw ClientError.missingSessionID
        }
        let result = try Self.firstJSONRPCPayload(in: data)
        guard result["result"] != nil else { throw ClientError.rpcError("initialize", result["error"]) }
        return id
    }

    func notifyInitialized(session: String) async throws {
        let (_, response) = try await post(Self.initializedBody, session: session)
        guard response.statusCode == 202 else { throw ClientError.status(response.statusCode, "notifications/initialized") }
    }

    /// Returns the tool names from `tools/list`.
    func toolsList(session: String) async throws -> [String] {
        let (data, response) = try await post(Self.toolsListBody, session: session)
        guard response.statusCode == 200 else { throw ClientError.status(response.statusCode, "tools/list") }
        let payload = try Self.firstJSONRPCPayload(in: data)
        guard let result = payload["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw ClientError.rpcError("tools/list", payload["error"])
        }
        return tools.compactMap { $0["name"] as? String }
    }

    /// Opens the standalone GET SSE stream, waits for the server's first bytes so the
    /// stream is genuinely live, then cancels the connection without a `DELETE`.
    func openAndDropSSE(session sessionID: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
        request.setValue("2025-03-26", forHTTPHeaderField: HTTPHeaderName.protocolVersion)

        let (bytes, response) = try await session.bytes(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        guard http.statusCode == 200 else { throw ClientError.status(http.statusCode, "GET SSE") }
        // The priming event arrives immediately; one byte proves the stream is open.
        var iterator = bytes.makeAsyncIterator()
        _ = try await iterator.next()
        bytes.task.cancel()
    }

    private func post(_ body: Data, session sessionID: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
            request.setValue("2025-03-26", forHTTPHeaderField: HTTPHeaderName.protocolVersion)
        }
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    /// Pulls the first non-empty `data:` line out of an SSE body and decodes it as a
    /// JSON object. (The transport emits an empty priming event first.)
    private static func firstJSONRPCPayload(in body: Data) throws -> [String: Any] {
        let text = String(decoding: body, as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix("data: ") {
            let json = line.dropFirst("data: ".count)
            guard !json.isEmpty else { continue }
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw ClientError.malformed(String(json))
            }
            return object
        }
        throw ClientError.malformed(text)
    }

    enum ClientError: Error, CustomStringConvertible {
        case status(Int, String)
        case missingSessionID
        case rpcError(String, Any?)
        case malformed(String)

        var description: String {
            switch self {
            case .status(let code, let what): "\(what): unexpected HTTP \(code)"
            case .missingSessionID: "initialize: no \(HTTPHeaderName.sessionID) header"
            case .rpcError(let what, let error): "\(what): JSON-RPC error \(error.map { "\($0)" } ?? "<none>")"
            case .malformed(let body): "malformed SSE body: \(body.prefix(200))"
            }
        }
    }
}
