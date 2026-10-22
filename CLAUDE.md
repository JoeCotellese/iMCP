# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

A Makefile wraps all build commands. Run `make help` to see available targets.

```bash
make build      # Release build
make debug      # Debug build
make install    # Build and copy to /Applications
make clean      # Clean build artifacts and DerivedData
make run        # Build and launch
make resolve    # Resolve Swift package dependencies
```

The project has two targets:
- `iMCP` - The main macOS app (SwiftUI menu bar app)
- `imcp-server` - CLI executable that gets bundled into the app at `iMCP.app/Contents/MacOS/imcp-server`

## Testing

Automated tests cover the Reminders ReminderKit features. Prerequisites: a reminder list named "iMCP Tests", and Reminders permission for the terminal that runs them.

```bash
cd Packages/ReminderKitBridge
swift test              # Bridge integration tests (writes to "iMCP Tests", deletes what it creates)
swift run rkprobe all   # Live ReminderKit probes, expect 8 PASS lines; re-run on every macOS beta

scripts/e2e-reminders.sh              # End to end against the installed app (make install, then relaunch iMCP first)
scripts/e2e-reminders.sh --self-test  # Checks the script's assertions without touching Reminders
```

The e2e script is the only level that exercises the app sandbox. `rkprobe` writes to the "iMCP Probes" and "iMCP Probes Grocery" lists and leaves its reminders there.

Manual testing is done via:
- MCP Inspector: `npx @modelcontextprotocol/inspector {server-command}`
- Companion app for debugging MCP servers

## Architecture Overview

iMCP is a macOS MCP (Model Context Protocol) server that exposes personal data (Calendar, Contacts, Location, Maps, Messages, Reminders, Weather) to AI clients like Claude Desktop.

```
┌─────────────────────────────────────────────────────────────┐
│  MCP Client (Claude Desktop)                                │
│       │                                                     │
│       ▼ stdio                                               │
│  ┌─────────────┐                                            │
│  │ imcp-server │  CLI - Bonjour browser, network→stdio      │
│  │ (CLI/)      │  proxy. Reads stdin, relays to app.        │
│  └──────┬──────┘                                            │
│         │ local network (Bonjour _mcp._tcp)                 │
│         ▼                                                   │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ iMCP.app (App/)                                     │    │
│  │  ┌────────────────────┐                             │    │
│  │  │ ServerController   │ Main orchestrator           │    │
│  │  │ - Network manager  │ Handles connections,        │    │
│  │  │ - Service registry │ approvals, UI state         │    │
│  │  └─────────┬──────────┘                             │    │
│  │            │                                        │    │
│  │  ┌─────────▼──────────────────────────────────┐     │    │
│  │  │ Services (App/Services/)                   │     │    │
│  │  │ Calendar, Contacts, Location, Maps,        │     │    │
│  │  │ Messages, Reminders, Weather, Capture,     │     │    │
│  │  │ Utilities                                  │     │    │
│  │  └────────────────────────────────────────────┘     │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

- **ServerController** (`App/Controllers/ServerController.swift`) - The main orchestrator. Manages network lifecycle, service registry, connection approval flow, and trusted clients.

- **Services** (`App/Services/`) - Each implements the `Service` protocol. Define tools via `ToolBuilder` result builder. Return JSON-LD via the Ontology package.

- **ReminderKitBridge** (`Packages/ReminderKitBridge/`) - Local package that calls Apple's private ReminderKit framework for reminder fields EventKit cannot reach (flagged so far). `Reminders.swift` saves through EventKit first, then applies extras through the bridge; a ReminderKit failure returns `warnings` instead of failing the tool. Private API: this fork can never ship on the App Store.

- **StdioProxy** (`CLI/main.swift`) - Actor that bridges network connections to stdio for MCP protocol. Handles Bonjour discovery and message buffering.

- **ConnectionState** (`CLI/main.swift`) - Actor for guarding async/await continuation safety.

### Data Flow

1. MCP client sends request via stdin to `imcp-server`
2. CLI discovers app via Bonjour, relays request over local network
3. App processes request through appropriate service
4. Service returns JSON-LD formatted response
5. Response relayed back through CLI to stdout

### Key Dependencies

- **MCP** - Model Context Protocol Swift SDK
- **Ontology** - JSON-LD structured data (Schema.org types)
- **Madrid** - iMessage database reading (TypedStream decoding)

## macOS Permissions

The app runs sandboxed and requires user permission for each service:
- Calendar (EventKit), Contacts, Location, WeatherKit
- Screen/audio capture (ScreenCaptureKit)
- Messages requires user to manually select `~/Library/Messages/chat.db` via file picker (sandbox workaround)

## Debugging

Copy server command from menu bar, then:
```bash
npx @modelcontextprotocol/inspector {paste-command}
open http://127.0.0.1:6274
```

## Notes

- Ignore spurious SourceKit "Cannot find type" or "No such module" warnings - assume types exist and modules are correctly installed
- Don't attempt to install new Swift packages without explicit request
- Recent commits focus on async/await continuation safety fixes
