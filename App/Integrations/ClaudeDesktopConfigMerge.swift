// ABOUTME: Pure merge of the Pontemac server entry into a Claude Desktop config dictionary.
// ABOUTME: Replaces the fork's old "iMCP" entry only when it points at a bundled imcp-server.

import Foundation
import MCP

enum ClaudeDesktopConfigMerge {
    static let serverKey = "Pontemac"
    static let legacyServerKey = "iMCP"
    static let legacyCommandSuffix = "/Contents/MacOS/imcp-server"

    static func upserting(_ server: Value, into config: [String: Value]) -> [String: Value] {
        var mcpServers = config["mcpServers"]?.objectValue ?? [:]
        if let command = mcpServers[legacyServerKey]?.objectValue?["command"]?.stringValue,
            command.hasSuffix(legacyCommandSuffix)
        {
            mcpServers[legacyServerKey] = nil
        }
        mcpServers[serverKey] = server

        var updatedConfig = config
        updatedConfig["mcpServers"] = .object(mcpServers)
        return updatedConfig
    }
}
