import Foundation
import HTTPTypes
import Hummingbird
import MCP
import NIOCore

enum HTTPRunner {
    static func run(store: CalendarStore, config: ServerConfig) async throws {
        // Build a custom validation pipeline that disables origin validation so
        // remote tailnet clients (whose Host header is not localhost) are accepted.
        let pipeline = StandardValidationPipeline(validators: [
            OriginValidator.disabled,
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])

        let transport = StatefulHTTPServerTransport(validationPipeline: pipeline)

        // Start the MCP server (wires up tool handlers) and connect to the transport.
        let server = await makeServer(store: store)
        try await server.start(transport: transport)

        // Build a Hummingbird router that bridges HTTP requests to the SDK transport.
        let router = Router()

        // Shared handler for POST, GET, and DELETE on /mcp.
        @Sendable func mcpHandler(request: Hummingbird.Request, context: some Hummingbird.RequestContext) async throws -> Hummingbird.Response {
            // --- Auth gate ---
            let authHeader = request.headers[.authorization]
            guard Auth.authorize(header: authHeader, token: config.token) else {
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

            // --- Dispatch to the SDK transport ---
            let sdkResponse = await transport.handleRequest(sdkRequest)

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
