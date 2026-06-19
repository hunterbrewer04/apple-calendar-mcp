import Foundation
import MCP

enum StdioRunner {
    static func run(store: CalendarStore) async throws {
        let server = await makeServer(store: store)
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
