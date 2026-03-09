// ABOUTME: Hummingbird HTTP server actor for MCP JSON-RPC transport.
// ABOUTME: Tries ports starting at 9847 until one binds. Exposes boundPort for TXT record.

import Foundation
import Hummingbird
import Logging
import MCP
import OSLog

private let log = Logger.server

/// Default starting port for the HTTP server
private let defaultStartPort = 9847
/// Maximum number of ports to try before giving up
private let maxPortAttempts = 10

/// HTTP server actor that handles MCP JSON-RPC requests over HTTP
actor HTTPMCPServer {
    private var serverTask: Task<Void, Swift.Error>?
    private let requestHandler: MCPRequestHandler
    private var sseConnections: [UUID: SSEConnection] = [:]
    private var isRunning = false

    /// The port the server successfully bound to (nil if not yet started)
    private(set) var boundPort: Int?

    /// Represents an active SSE connection for notifications
    struct SSEConnection: Sendable {
        let id: UUID
        let stream: AsyncStream<String>.Continuation
    }

    init(requestHandler: MCPRequestHandler) {
        self.requestHandler = requestHandler
    }

    /// Start the HTTP server, trying successive ports if needed
    func start() async throws {
        guard !isRunning else {
            log.warning("HTTP server already running")
            return
        }

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
                // Cannot parse request id, return HTTP error only (no JSON-RPC body)
                return Response(status: .badRequest)
            }

            let bodyData = Data(buffer: bodyBuffer)

            guard let bodyString = String(data: bodyData, encoding: .utf8) else {
                log.error("Invalid UTF-8 in request body")
                // Cannot parse request id, return HTTP error only (no JSON-RPC body)
                return Response(status: .badRequest)
            }

            log.debug("Received MCP request: \(bodyString.prefix(200))...")

            // Extract the request id for use in error responses.
            // Per JSON-RPC 2.0, error responses MUST include the same id as the request.
            // If the request has no id (notification), we must not send an error response.
            let requestJSON = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            let requestId = requestJSON?["id"]

            /// Build a JSON-RPC error response using the request's id.
            /// Returns nil if the request had no id (notification), since notifications
            /// must never receive a response per JSON-RPC 2.0.
            func makeErrorResponse(code: Int, message: String, status: HTTPResponse.Status) -> Response {
                // Only send JSON-RPC error responses for requests (which have an id).
                guard let id = requestId, !(id is NSNull) else {
                    log.debug("Suppressing error response for request with no valid id (notification or parse failure)")
                    return Response(status: status)
                }

                let idJson: String
                if let intId = id as? Int {
                    idJson = "\(intId)"
                } else if let strId = id as? String {
                    idJson = "\"\(strId)\""
                } else {
                    // Unrecognized id type — don't send a JSON-RPC response
                    return Response(status: status)
                }

                let body = #"{"jsonrpc":"2.0","error":{"code":\#(code),"message":"\#(message)"},"id":\#(idJson)}"#
                return Response(
                    status: status,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: ByteBuffer(string: body))
                )
            }

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
                    return makeErrorResponse(code: -32700, message: message, status: .badRequest)
                case .methodNotFound(let method):
                    return makeErrorResponse(code: -32601, message: "Method not found: \(method)", status: .ok)
                case .internalError(let message):
                    return makeErrorResponse(code: -32603, message: message, status: .internalServerError)
                }
            } catch {
                log.error("Error handling MCP request: \(error)")
                return makeErrorResponse(code: -32603, message: "Internal error", status: .internalServerError)
            }
        }

        // Try successive ports until one binds successfully
        var lastError: Swift.Error?
        for portOffset in 0..<maxPortAttempts {
            let port = defaultStartPort + portOffset
            log.info("Attempting to start HTTP MCP server on localhost:\(port)")

            let app = Application(
                router: router,
                configuration: .init(
                    address: .hostname("127.0.0.1", port: port),
                    serverName: "iMCP"
                ),
                logger: Logging.Logger(label: "me.mattt.iMCP.http")
            )

            // Start the server in a task
            let startTask = Task {
                try await app.runService()
            }

            // Verify the server started by polling health endpoint
            // Retry a few times to give the server time to bind
            var serverReady = false
            for attempt in 1...5 {
                try await Task.sleep(for: .milliseconds(100))

                if await isPortListening(port: port) {
                    serverReady = true
                    break
                }
                log.debug("Health check attempt \(attempt) on port \(port) - not ready yet")
            }

            if serverReady {
                // Success - record the port and keep the server running
                self.boundPort = port
                self.isRunning = true
                self.serverTask = startTask
                log.notice("HTTP MCP server started on http://127.0.0.1:\(port)")
                return
            } else {
                // Port didn't become available, cancel task and try next
                startTask.cancel()
                log.warning("Port \(port) did not become available after 500ms, trying next")
                lastError = HTTPServerError.portInUse(port)
            }
        }

        // All ports failed
        log.error("Failed to bind HTTP server after trying \(maxPortAttempts) ports")
        throw lastError ?? HTTPServerError.allPortsInUse
    }

    /// Check if a port is listening by attempting a quick connection
    private func isPortListening(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Expected to fail if port not yet listening
        }
        return false
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

/// Errors that can occur when starting the HTTP server
enum HTTPServerError: Swift.Error {
    case portInUse(Int)
    case allPortsInUse
}
