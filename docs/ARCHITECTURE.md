# iMCP Architecture

This document provides a senior developer overview of the iMCP codebase architecture.

## Overview

iMCP is a macOS MCP (Model Context Protocol) server that exposes personal data to AI clients like Claude Desktop. It bridges macOS frameworks (EventKit, Contacts, CoreLocation, etc.) with the MCP protocol, allowing AI assistants to access calendar events, contacts, location, and more.

**Key architectural decisions:**
- Dual transport: HTTP (default) and Bonjour for network discovery
- Actor-based concurrency throughout
- Service-oriented design with pluggable data providers
- JSON-LD responses via the Ontology package

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  MCP Client (Claude Desktop)                                    │
│       │                                                         │
│       ▼ stdio                                                   │
│  ┌─────────────┐                                                │
│  │ imcp-server │  CLI - Reads transport config, proxies         │
│  │ (CLI/)      │  stdin/stdout ↔ HTTP or Bonjour                │
│  └──────┬──────┘                                                │
│         │                                                       │
│         ├─── HTTP POST localhost:9847/mcp ───┐                  │
│         │                                    │                  │
│         └─── Bonjour _mcp._tcp.local. ──┐    │                  │
│                                         │    │                  │
│  ┌──────────────────────────────────────┴────┴─────────────┐    │
│  │ iMCP.app (App/)                                         │    │
│  │                                                         │    │
│  │  ┌────────────────────────────────────────────────┐     │    │
│  │  │ ServerController (@MainActor)                  │     │    │
│  │  │ - Transport lifecycle (HTTP/Bonjour)           │     │    │
│  │  │ - Connection approval flow                     │     │    │
│  │  │ - Service enablement bindings                  │     │    │
│  │  │ - Trusted client management                    │     │    │
│  │  └───────────────┬────────────────────────────────┘     │    │
│  │                  │                                      │    │
│  │  ┌───────────────┴────────────────────────────────┐     │    │
│  │  │ Services (10 implementations)                  │     │    │
│  │  │ Calendar, Contacts, Location, Maps, Messages,  │     │    │
│  │  │ Reminders, Weather, Shortcuts, Capture, Utils  │     │    │
│  │  └────────────────────────────────────────────────┘     │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
iMCP/
├── App/
│   ├── Controllers/
│   │   └── ServerController.swift    # Main orchestrator (includes embedded actors)
│   ├── Models/
│   │   ├── Service.swift             # Service protocol + ToolBuilder
│   │   └── Tool.swift                # Tool definition with JSON-LD encoding
│   ├── Services/                     # 10 service implementations
│   ├── HTTP/
│   │   ├── HTTPServer.swift          # Hummingbird HTTP server actor
│   │   └── MCPRequestHandler.swift   # JSON-RPC routing actor
│   ├── Views/                        # SwiftUI (menu bar, settings, approval)
│   └── Extensions/                   # Framework extensions
├── CLI/
│   └── main.swift                    # Stdio proxy (HTTP or Bonjour client)
└── docs/
    └── ARCHITECTURE.md               # This file
```

## Core Components

### ServerController

**File:** `App/Controllers/ServerController.swift`

The main orchestrator. Responsibilities:
- Manages HTTP server and Bonjour network manager lifecycle
- Holds service enablement state via `@AppStorage`
- Handles connection approval flow and trusted client list
- Writes transport config for CLI to read

Contains embedded actors:
- `ServerNetworkManager` - Bonjour advertisement and connection handling
- `MCPConnectionManager` - Individual MCP connection lifecycle
- `NetworkDiscoveryManager` - Bonjour service advertisement with TXT records

### HTTP Transport

**Files:** `App/HTTP/HTTPServer.swift`, `App/HTTP/MCPRequestHandler.swift`

- `HTTPMCPServer` actor binds to localhost:9847 (or next available port)
- `MCPRequestHandler` actor routes JSON-RPC methods and manages client sessions
- Session timeout: 30 minutes, cleanup every 60 seconds
- Approval returns 202 (pending) until user approves, then 200

### CLI Proxy

**File:** `CLI/main.swift`

Bridges MCP clients (stdin/stdout) to the app:
1. Reads `~/Library/Application Support/iMCP/transport.json`
2. Selects `HTTPMCPService` or `MCPService` (Bonjour)
3. Relays messages bidirectionally with proper JSON-RPC framing

Key actors:
- `ConfigBasedMCPService` - Transport selection
- `HTTPMCPService` - HTTP client with approval polling
- `MCPService` / `StdioProxy` - Bonjour discovery and network-to-stdio proxy

## Service Architecture

### Service Protocol

```swift
protocol Service {
    @ToolBuilder var tools: [Tool] { get }
    var isActivated: Bool { get async }
    func activate() async throws
}
```

- `tools` - Declares available tools using result builder syntax
- `isActivated` - Checks OS permission status
- `activate()` - Requests permission from user

### Tool Definition

```swift
Tool(
    name: "events_fetch",
    description: "Get calendar events",
    inputSchema: .object(properties: [...]),
    annotations: .init(title: "Fetch Events", readOnlyHint: true)
) { arguments in
    // Implementation returns Encodable, auto-converted to JSON-LD
}
```

Tools encode results via the Ontology package for Schema.org JSON-LD compliance.

### Service Registry

`ServiceRegistry` in ServerController defines all services with metadata:
- Display name, icon, color
- Category (Personal Data, Productivity, Media & Home, System)
- AppStorage binding for enablement

## Data Flow

### HTTP Transport (Default)

```
Client stdin → CLI → HTTP POST /mcp → HTTPServer → MCPRequestHandler
                                                          │
                                               Service.call(tool, args)
                                                          │
                                               Tool implementation
                                                          │
                                               JSON-LD encoding
                                                          │
Client stdout ← CLI ← HTTP 200 ← JSON-RPC response ←──────┘
```

### Bonjour Transport

```
Client stdin → CLI StdioProxy → NWConnection → ServerNetworkManager
                                                       │
                                            MCPConnectionManager
                                                       │
                                            MCP.Server (SDK)
                                                       │
                                            Tool handler
                                                       │
Client stdout ← CLI ← NWConnection ← JSON-RPC ←────────┘
```

## Concurrency Model

### Actors

| Actor | Location | Purpose |
|-------|----------|---------|
| `ServerController` | ServerController.swift | Main orchestrator (@MainActor) |
| `ServerNetworkManager` | ServerController.swift | Bonjour connection management |
| `MCPConnectionManager` | ServerController.swift | Single connection lifecycle |
| `HTTPMCPServer` | HTTPServer.swift | HTTP server lifecycle |
| `MCPRequestHandler` | MCPRequestHandler.swift | Session and request routing |
| `StdioProxy` | CLI/main.swift | Network ↔ stdio bridge |
| `ConnectionState` | CLI/main.swift | Continuation safety guard |

### Continuation Safety Pattern

Used throughout to prevent multiple resumptions:

```swift
let lock = NSLock()
var hasResumed = false

let resumeOnce = { (value: Bool) in
    lock.lock()
    defer { lock.unlock() }
    guard !hasResumed else { return }
    hasResumed = true
    continuation.resume(returning: value)
}
```

## Configuration

### Transport Config

**Location:** `~/Library/Application Support/iMCP/transport.json`

```json
{"transport": "http", "httpPort": 9847}
```

Written by app, read by CLI to select transport.

### AppStorage Keys

| Key | Default | Purpose |
|-----|---------|---------|
| `useHTTPTransport` | `true` | HTTP vs Bonjour transport |
| `isEnabled` | `true` | Global server enable/disable |
| `calendarEnabled` | `false` | Per-service enablement |
| `trustedClients` | `[]` | JSON-encoded trusted client IDs |

## Connection Approval

1. New client connects (HTTP or Bonjour)
2. Check `trustedClients` - auto-approve if present
3. Otherwise show `ConnectionApprovalView` window
4. User approves/denies, optionally checks "Always Trust"
5. Trusted clients stored in AppStorage

HTTP transport returns 202 while pending, CLI polls with 2-second intervals.

## Security Model

- **Local-only:** HTTP binds to 127.0.0.1, Bonjour uses `acceptLocalOnly`
- **Approval required:** Every new client needs user approval
- **OS permissions:** Each service requires framework-level permission
- **Fine-grained control:** Individual service toggles in Settings

## Dependencies

| Package | Purpose |
|---------|---------|
| MCP | Model Context Protocol SDK |
| Ontology | Schema.org JSON-LD encoding |
| Hummingbird | HTTP server framework |
| Madrid | iMessage database reading |

## Key Patterns

### Service Implementation

```swift
final class CalendarService: Service {
    static let shared = CalendarService()
    private let eventStore = EKEventStore()

    var isActivated: Bool {
        get async { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    }

    var tools: [Tool] {
        Tool(name: "calendars_list", ...) { args in ... }
        Tool(name: "events_fetch", ...) { args in ... }
    }
}
```

### Error Handling

HTTP responses map to MCP conventions:
- 200: Success with JSON-RPC result
- 202: Pending approval (client should retry)
- 401: Unauthorized (client denied)
- 400: Parse error (invalid JSON-RPC)

### Health Monitoring

- Bonjour listener checked every 10 seconds, auto-restarts if failed
- HTTP sessions cleaned up every 60 seconds (30-min timeout)
- Connection setup times out after 10 seconds

## Adding a New Service

1. Create `App/Services/NewService.swift` implementing `Service` protocol
2. Add to `ServiceRegistry.services` array
3. Add `@AppStorage` binding in ServerController
4. Add to `ServiceRegistry.configureServices()` with metadata
5. Request appropriate entitlements in `App.entitlements`

## Debugging

```bash
# Copy server command from menu bar, then:
npx @modelcontextprotocol/inspector {paste-command}
open http://127.0.0.1:6274

# View logs
log stream --predicate 'subsystem == "me.mattt.iMCP"' --level debug
```
