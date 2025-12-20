// ABOUTME: Handles MCP JSON-RPC requests by parsing and routing to appropriate services.
// ABOUTME: Manages client sessions, connection approval, and tool execution.

import Foundation
import JSONSchema
import MCP
import Ontology
import OSLog

private let log = Logger.server

/// Handles MCP JSON-RPC requests over HTTP
actor MCPRequestHandler {
    /// Errors that can occur during request handling
    enum RequestError: Swift.Error {
        case unauthorized
        case pendingApproval
        case parseError(String)
        case methodNotFound(String)
        case internalError(String)
    }

    /// Client session state
    struct ClientSession {
        let clientID: String
        var clientInfo: MCP.Client.Info?
        var isApproved: Bool
        var capabilities: MCP.Client.Capabilities?
    }

    private var sessions: [String: ClientSession] = [:]
    private var serviceBindings: [String: Bool] = [:]
    private var isEnabled: Bool = true

    /// Connection approval handler - called when a new client needs approval
    private var approvalHandler: ((String, MCP.Client.Info) async -> Bool)?

    /// Server info
    private let serverName: String
    private let serverVersion: String

    init() {
        self.serverName = Bundle.main.name ?? "iMCP"
        self.serverVersion = Bundle.main.shortVersionString ?? "unknown"
    }

    /// Set the connection approval handler
    func setApprovalHandler(_ handler: @escaping (String, MCP.Client.Info) async -> Bool) {
        self.approvalHandler = handler
    }

    /// Update service bindings
    func updateServiceBindings(_ bindings: [String: Bool]) {
        self.serviceBindings = bindings
    }

    /// Set enabled state
    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
    }

    /// Handle an incoming JSON-RPC request
    func handleRequest(_ requestBody: String, clientID: String) async throws -> String {
        // Parse the JSON-RPC request
        guard let data = requestBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            throw RequestError.parseError("Invalid JSON-RPC request")
        }

        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        log.debug("Handling method: \(method) for client: \(clientID)")

        // Route to appropriate handler
        switch method {
        case "initialize":
            return try await handleInitialize(id: id, params: params, clientID: clientID)

        case "initialized":
            return makeSuccessResponse(id: id, result: [:])

        case "ping":
            return makeSuccessResponse(id: id, result: [:])

        case "tools/list":
            return try await handleToolsList(id: id, clientID: clientID)

        case "tools/call":
            return try await handleToolsCall(id: id, params: params, clientID: clientID)

        case "prompts/list":
            return makeSuccessResponse(id: id, result: ["prompts": []])

        case "resources/list":
            return makeSuccessResponse(id: id, result: ["resources": []])

        default:
            throw RequestError.methodNotFound(method)
        }
    }

    /// Handle initialize request
    private func handleInitialize(id: Any?, params: [String: Any], clientID: String) async throws -> String {
        // Parse client info from params
        guard let clientInfoDict = params["clientInfo"] as? [String: Any],
              let clientName = clientInfoDict["name"] as? String,
              let clientVersion = clientInfoDict["version"] as? String else {
            throw RequestError.parseError("Missing or invalid clientInfo")
        }

        let clientInfo = MCP.Client.Info(name: clientName, version: clientVersion)

        // Check if we need approval
        var session = sessions[clientID] ?? ClientSession(
            clientID: clientID,
            clientInfo: nil,
            isApproved: false,
            capabilities: nil
        )

        session.clientInfo = clientInfo

        if !session.isApproved {
            // Request approval
            if let handler = approvalHandler {
                let approved = await handler(clientID, clientInfo)
                if !approved {
                    throw RequestError.unauthorized
                }
                session.isApproved = true
            } else {
                // No approval handler, auto-approve (shouldn't happen in production)
                log.warning("No approval handler set, auto-approving client: \(clientID)")
                session.isApproved = true
            }
        }

        // Parse capabilities
        if let capsDict = params["capabilities"] as? [String: Any] {
            session.capabilities = parseCapabilities(capsDict)
        }

        sessions[clientID] = session

        log.notice("Client initialized: \(clientName) v\(clientVersion)")

        // Return server capabilities
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "serverInfo": [
                "name": serverName,
                "version": serverVersion
            ],
            "capabilities": [
                "tools": [
                    "listChanged": true
                ]
            ]
        ]

        return makeSuccessResponse(id: id, result: result)
    }

    /// Handle tools/list request
    private func handleToolsList(id: Any?, clientID: String) async throws -> String {
        // Check if client is approved
        guard let session = sessions[clientID], session.isApproved else {
            throw RequestError.unauthorized
        }

        var tools: [[String: Any]] = []

        if isEnabled {
            for service in ServiceRegistry.services {
                let serviceID = String(describing: type(of: service))

                if serviceBindings[serviceID] == true {
                    for tool in service.tools {
                        // Encode JSONSchema to dictionary
                        let schemaDict = encodeJSONSchema(tool.inputSchema)

                        var toolDict: [String: Any] = [
                            "name": tool.name,
                            "description": tool.description,
                            "inputSchema": schemaDict
                        ]

                        // Add annotations
                        let annotations = tool.annotations
                        var annotationsDict: [String: Any] = [:]
                        if let title = annotations.title {
                            annotationsDict["title"] = title
                        }
                        if let readOnly = annotations.readOnlyHint {
                            annotationsDict["readOnlyHint"] = readOnly
                        }
                        if let destructive = annotations.destructiveHint {
                            annotationsDict["destructiveHint"] = destructive
                        }
                        if let idempotent = annotations.idempotentHint {
                            annotationsDict["idempotentHint"] = idempotent
                        }
                        if let openWorld = annotations.openWorldHint {
                            annotationsDict["openWorldHint"] = openWorld
                        }
                        if !annotationsDict.isEmpty {
                            toolDict["annotations"] = annotationsDict
                        }

                        tools.append(toolDict)
                    }
                }
            }
        }

        log.info("Returning \(tools.count) tools for client: \(clientID)")

        return makeSuccessResponse(id: id, result: ["tools": tools])
    }

    /// Handle tools/call request
    private func handleToolsCall(id: Any?, params: [String: Any], clientID: String) async throws -> String {
        // Check if client is approved
        guard let session = sessions[clientID], session.isApproved else {
            throw RequestError.unauthorized
        }

        guard isEnabled else {
            return makeToolResult(id: id, content: [["type": "text", "text": "iMCP is currently disabled"]], isError: true)
        }

        guard let toolName = params["name"] as? String else {
            throw RequestError.parseError("Missing tool name")
        }

        let rawArguments = params["arguments"] as? [String: Any] ?? [:]

        // Convert raw arguments to Value dictionary
        let arguments = convertToValueDict(rawArguments)

        log.notice("Tool call: \(toolName) from client: \(clientID)")

        // Find and execute the tool
        for service in ServiceRegistry.services {
            let serviceID = String(describing: type(of: service))

            if serviceBindings[serviceID] == true {
                do {
                    guard let value = try await service.call(tool: toolName, with: arguments) else {
                        continue
                    }

                    log.notice("Tool \(toolName) executed successfully")

                    // Format the response based on value type
                    switch value {
                    case .data(let mimeType?, let data) where mimeType.hasPrefix("audio/"):
                        return makeToolResult(id: id, content: [[
                            "type": "audio",
                            "data": data.base64EncodedString(),
                            "mimeType": mimeType
                        ]], isError: false)

                    case .data(let mimeType?, let data) where mimeType.hasPrefix("image/"):
                        return makeToolResult(id: id, content: [[
                            "type": "image",
                            "data": data.base64EncodedString(),
                            "mimeType": mimeType
                        ]], isError: false)

                    default:
                        let encoder = JSONEncoder()
                        encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
                        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

                        let data = try encoder.encode(value)
                        let text = String(data: data, encoding: .utf8) ?? ""

                        return makeToolResult(id: id, content: [["type": "text", "text": text]], isError: false)
                    }
                } catch {
                    log.error("Error executing tool \(toolName): \(error)")
                    return makeToolResult(id: id, content: [["type": "text", "text": "Error: \(error)"]], isError: true)
                }
            }
        }

        log.error("Tool not found or service not enabled: \(toolName)")
        return makeToolResult(id: id, content: [["type": "text", "text": "Tool not found or service not enabled: \(toolName)"]], isError: true)
    }

    /// Convert raw dictionary arguments to Value dictionary
    private func convertToValueDict(_ dict: [String: Any]) -> [String: Value] {
        var result: [String: Value] = [:]
        for (key, rawValue) in dict {
            result[key] = convertToValue(rawValue)
        }
        return result
    }

    /// Convert a raw value to MCP.Value
    private func convertToValue(_ rawValue: Any) -> Value {
        switch rawValue {
        case let string as String:
            return .string(string)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let bool as Bool:
            return .bool(bool)
        case let array as [Any]:
            return .array(array.map { convertToValue($0) })
        case let dict as [String: Any]:
            return .object(convertToValueDict(dict))
        case is NSNull:
            return .null
        default:
            // Try to convert to string as fallback
            return .string(String(describing: rawValue))
        }
    }

    /// Encode JSONSchema to a dictionary for JSON serialization
    private func encodeJSONSchema(_ schema: JSONSchema) -> [String: Any] {
        // Encode the schema to JSON and then decode as dictionary
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(schema),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["type": "object"]
        }

        return dict
    }

    /// Parse client capabilities from dictionary
    private func parseCapabilities(_ dict: [String: Any]) -> MCP.Client.Capabilities {
        // For now, return default capabilities
        // This can be expanded to parse specific capability fields
        return MCP.Client.Capabilities()
    }

    /// Create a JSON-RPC success response
    private func makeSuccessResponse(id: Any?, result: [String: Any]) -> String {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]

        if let id = id {
            response["id"] = id
        }

        return serializeJSON(response)
    }

    /// Create a tool result response
    private func makeToolResult(id: Any?, content: [[String: Any]], isError: Bool) -> String {
        var result: [String: Any] = [
            "content": content
        ]
        if isError {
            result["isError"] = true
        }

        return makeSuccessResponse(id: id, result: result)
    }

    /// Serialize dictionary to JSON string
    private func serializeJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Serialization error"},"id":null}"#
        }
        return string
    }

    /// Check if a client is approved
    func isClientApproved(_ clientID: String) -> Bool {
        return sessions[clientID]?.isApproved ?? false
    }

    /// Remove a client session
    func removeSession(_ clientID: String) {
        sessions.removeValue(forKey: clientID)
    }
}
