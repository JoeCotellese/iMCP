// ABOUTME: Hummingbird HTTP server actor for MCP JSON-RPC transport.
// ABOUTME: Listens on localhost:9847, handles POST requests, and SSE for notifications.

import Foundation
import Hummingbird
import Logging
import MCP
import OSLog

private let log = Logger.server

/// Port for the HTTP server
let mcpHTTPPort = 9847

/// HTTP server actor that handles MCP JSON-RPC requests over HTTP
actor HTTPMCPServer {
    private var serverTask: Task<Void, Swift.Error>?
    private let requestHandler: MCPRequestHandler
    private var sseConnections: [UUID: SSEConnection] = [:]
    private var isRunning = false

    /// Represents an active SSE connection for notifications
    struct SSEConnection: Sendable {
        let id: UUID
        let stream: AsyncStream<String>.Continuation
    }

    init(requestHandler: MCPRequestHandler) {
        self.requestHandler = requestHandler
    }

    /// Start the HTTP server
    func start() async throws {
        guard !isRunning else {
            log.warning("HTTP server already running")
            return
        }

        log.info("Starting HTTP MCP server on localhost:\(mcpHTTPPort)")

        isRunning = true

        // Capture self for use in closures
        let handler = self.requestHandler

        // Build the router
        let router = Router()

        // Health check endpoint
        router.get("/health") { _, _ in
            return "OK"
        }

        // MCP JSON-RPC endpoint
        router.post("/mcp") { request, _ -> Response in
            // Read request body
            var body = request.body
            guard let bodyBuffer = try? await body.collect(upTo: 10 * 1024 * 1024) else {
                log.error("Failed to read request body")
                return Response(
                    status: .badRequest,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: ByteBuffer(string: #"{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"},"id":null}"#))
                )
            }

            let bodyData = Data(buffer: bodyBuffer)

            guard let bodyString = String(data: bodyData, encoding: .utf8) else {
                log.error("Invalid UTF-8 in request body")
                return Response(
                    status: .badRequest,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: ByteBuffer(string: #"{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error: invalid UTF-8"},"id":null}"#))
                )
            }

            log.debug("Received MCP request: \(bodyString.prefix(200))...")

            // Get client identifier from header or generate one
            let clientID = request.headers[.init("X-MCP-Client-ID")!] ?? "http-client"

            // Process the request through MCPRequestHandler
            do {
                let responseString = try await handler.handleRequest(bodyString, clientID: clientID)

                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: ByteBuffer(string: responseString))
                )
            } catch let error as MCPRequestHandler.RequestError {
                switch error {
                case .unauthorized:
                    return Response(status: .unauthorized)
                case .pendingApproval:
                    return Response(
                        status: .accepted,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: #"{"status":"pending_approval"}"#))
                    )
                case .parseError(let message):
                    return Response(
                        status: .badRequest,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: #"{"jsonrpc":"2.0","error":{"code":-32700,"message":"\#(message)"},"id":null}"#))
                    )
                case .methodNotFound(let method):
                    return Response(
                        status: .ok,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: #"{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found: \#(method)"},"id":null}"#))
                    )
                case .internalError(let message):
                    return Response(
                        status: .internalServerError,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"\#(message)"},"id":null}"#))
                    )
                }
            } catch {
                log.error("Error handling MCP request: \(error)")
                return Response(
                    status: .internalServerError,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: ByteBuffer(string: #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":null}"#))
                )
            }
        }

        // Create application
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: mcpHTTPPort),
                serverName: "iMCP"
            ),
            logger: Logging.Logger(label: "me.mattt.iMCP.http")
        )

        // Run the server in a task
        serverTask = Task {
            try await app.runService()
        }

        log.notice("HTTP MCP server started on http://127.0.0.1:\(mcpHTTPPort)")
    }

    /// Stop the HTTP server
    func stop() async {
        log.info("Stopping HTTP MCP server")
        isRunning = false

        // Cancel the server task
        serverTask?.cancel()
        serverTask = nil

        // Close all SSE connections
        for (_, connection) in sseConnections {
            connection.stream.finish()
        }
        sseConnections.removeAll()

        log.notice("HTTP MCP server stopped")
    }

    /// Send a notification to all connected SSE clients
    func sendNotification(_ notification: String) async {
        log.debug("Broadcasting notification to \(self.sseConnections.count) SSE clients")
        for (_, connection) in self.sseConnections {
            connection.stream.yield(notification)
        }
    }

    /// Remove a disconnected SSE connection
    func removeSSEConnection(_ id: UUID) {
        if let connection = sseConnections.removeValue(forKey: id) {
            connection.stream.finish()
            log.debug("Removed SSE connection: \(id)")
        }
    }

    /// Check if server is running
    func getIsRunning() -> Bool {
        return isRunning
    }
}
