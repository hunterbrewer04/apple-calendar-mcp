import XCTest
import MCP
@testable import apple_calendar

/// Drives `SessionManager` directly with SDK `HTTPRequest`s (no sockets), so the
/// LRU cap can be checked deterministically and fast.
final class SessionManagerTests: XCTestCase {
    private static let initializeBody = Data("""
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}
    """.utf8)
    private static let toolsListBody = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)

    private static let postHeaders = [
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
    ]

    private func initialize(_ manager: SessionManager) async throws -> String {
        let response = await manager.handle(
            MCP.HTTPRequest(method: "POST", headers: Self.postHeaders, body: Self.initializeBody, path: "/mcp"),
            client: "test")
        XCTAssertEqual(response.statusCode, 200)
        return try XCTUnwrap(response.headers[HTTPHeaderName.sessionID], "initialize must mint a session id")
    }

    private func toolsList(_ manager: SessionManager, session: String) async -> Int {
        var headers = Self.postHeaders
        headers[HTTPHeaderName.sessionID] = session
        let response = await manager.handle(
            MCP.HTTPRequest(method: "POST", headers: headers, body: Self.toolsListBody, path: "/mcp"),
            client: "test")
        return response.statusCode
    }

    private func delete(_ manager: SessionManager, session: String) async -> Int {
        let response = await manager.handle(
            MCP.HTTPRequest(method: "DELETE", headers: [HTTPHeaderName.sessionID: session], path: "/mcp"),
            client: "test")
        return response.statusCode
    }

    func testInitializeCreatesRoutableSession() async throws {
        let manager = SessionManager(store: MockCalendarStore(), maxSessions: 4)
        let session = try await initialize(manager)
        let count = await manager.count
        XCTAssertEqual(count, 1)
        let status = await toolsList(manager, session: session)
        XCTAssertEqual(status, 200)
    }

    func testUnknownSessionIs404AndMissingHeaderIs400() async throws {
        let manager = SessionManager(store: MockCalendarStore(), maxSessions: 4)
        let unknown = await toolsList(manager, session: "nope")
        XCTAssertEqual(unknown, 404)
        let missing = await manager.handle(
            MCP.HTTPRequest(method: "POST", headers: Self.postHeaders, body: Self.toolsListBody, path: "/mcp"),
            client: "test")
        XCTAssertEqual(missing.statusCode, 400)
    }

    func testCapEvictsLeastRecentlyCreated() async throws {
        let cap = 3
        let manager = SessionManager(store: MockCalendarStore(), maxSessions: cap)
        var ids: [String] = []
        for _ in 0..<(cap + 2) {
            ids.append(try await initialize(manager))
            let count = await manager.count
            XCTAssertLessThanOrEqual(count, cap, "table must never exceed the cap")
        }
        let count = await manager.count
        XCTAssertEqual(count, cap)

        // The two oldest were evicted; everything newer still routes.
        for evicted in ids.prefix(2) {
            let status = await toolsList(manager, session: evicted)
            XCTAssertEqual(status, 404, "evicted session \(evicted) should be gone")
        }
        for live in ids.suffix(cap) {
            let status = await toolsList(manager, session: live)
            XCTAssertEqual(status, 200, "session \(live) should still be live")
        }
    }

    func testRecentlyUsedSessionSurvivesEviction() async throws {
        let manager = SessionManager(store: MockCalendarStore(), maxSessions: 3)
        let a = try await initialize(manager)
        let b = try await initialize(manager)
        let c = try await initialize(manager)

        // Touch A so B becomes the least recently used.
        let touched = await toolsList(manager, session: a)
        XCTAssertEqual(touched, 200)

        let d = try await initialize(manager)
        let count = await manager.count
        XCTAssertEqual(count, 3)

        let bStatus = await toolsList(manager, session: b)
        XCTAssertEqual(bStatus, 404, "B was least recently used and should be evicted")
        for live in [a, c, d] {
            let status = await toolsList(manager, session: live)
            XCTAssertEqual(status, 200)
        }
    }

    func testCloseAllDropsEverySessionAndRefusesNewOnes() async throws {
        let manager = SessionManager(store: MockCalendarStore(), maxSessions: 4)
        let a = try await initialize(manager)
        _ = try await initialize(manager)

        await manager.closeAll()
        let count = await manager.count
        XCTAssertEqual(count, 0)
        let aStatus = await toolsList(manager, session: a)
        XCTAssertEqual(aStatus, 404)

        let refused = await manager.handle(
            MCP.HTTPRequest(method: "POST", headers: Self.postHeaders, body: Self.initializeBody, path: "/mcp"),
            client: "test")
        XCTAssertEqual(refused.statusCode, 503)
        let after = await manager.count
        XCTAssertEqual(after, 0)
    }

    func testDeleteFreesSlotWithoutEvicting() async throws {
        let manager = SessionManager(store: MockCalendarStore(), maxSessions: 2)
        let a = try await initialize(manager)
        let b = try await initialize(manager)

        let deleted = await delete(manager, session: a)
        XCTAssertEqual(deleted, 200)
        var count = await manager.count
        XCTAssertEqual(count, 1)

        // Room was freed by the DELETE, so creating C evicts nothing: B survives.
        let c = try await initialize(manager)
        count = await manager.count
        XCTAssertEqual(count, 2)
        let bStatus = await toolsList(manager, session: b)
        XCTAssertEqual(bStatus, 200)
        let cStatus = await toolsList(manager, session: c)
        XCTAssertEqual(cStatus, 200)
        let aStatus = await toolsList(manager, session: a)
        XCTAssertEqual(aStatus, 404)
    }
}
