// ABOUTME: Unit tests for ClaudeDesktopConfigMerge, the Claude Desktop config migration to Pontemac.
// ABOUTME: Covers replacing the fork's own "iMCP" entry and keeping one that belongs to someone else.

import MCP
import Testing

@Suite struct ClaudeDesktopConfigMergeTests {
    private let pontemac: Value = .object([
        "command": .string("/Applications/Pontemac.app/Contents/MacOS/pontemac-server")
    ])
    private let other: Value = .object([
        "command": .string("/usr/local/bin/other-server"),
        "args": .array([.string("--flag")]),
    ])

    @Test func testReplacesOwnedIMCPEntry() throws {
        let config: [String: Value] = [
            "mcpServers": .object([
                "iMCP": .object([
                    "command": .string("/Applications/iMCP.app/Contents/MacOS/imcp-server")
                ]),
                "other": other,
            ]),
            "globalShortcut": .string("Cmd+Space"),
        ]

        let merged = ClaudeDesktopConfigMerge.upserting(pontemac, into: config)

        let servers = try #require(merged["mcpServers"]?.objectValue)
        #expect(Set(servers.keys) == ["Pontemac", "other"])
        #expect(servers["Pontemac"] == pontemac)
        #expect(servers["other"] == other)
        #expect(merged["globalShortcut"] == .string("Cmd+Space"))
    }

    @Test func testKeepsForeignIMCPEntry() throws {
        let foreign: Value = .object([
            "command": .string("/Users/someone/bin/imcp-proxy")
        ])
        let config: [String: Value] = [
            "mcpServers": .object(["iMCP": foreign])
        ]

        let merged = ClaudeDesktopConfigMerge.upserting(pontemac, into: config)

        let servers = try #require(merged["mcpServers"]?.objectValue)
        #expect(Set(servers.keys) == ["Pontemac", "iMCP"])
        #expect(servers["iMCP"] == foreign)
        #expect(servers["Pontemac"] == pontemac)
    }
}
