# DoD results: #36 ReminderKitBridge package and flagged reminders

1. Date: 2026-10-22 10:35 EDT
2. Issue: #36
3. Branch: feature/36-reminderkit-bridge-flagged
4. Commit: fe31387
5. Status: PASS
6. Domain: swift (no `[ui]` criteria; acceptance channel is `scripts/e2e-reminders.sh`, per the issue's DoD)

## Unit suite

1. `swift test` in `Packages/ReminderKitBridge`: 2 tests in 1 suite passed, 0 failures, no stray log or warning lines.

## Acceptance test (committed at /ready, b1fe386, unchanged)

1. `scripts/e2e-reminders.sh --self-test`: PASS self_test.
2. `scripts/e2e-reminders.sh flag_create flag_update fetch_flagged_field` against /Applications/iMCP.app built from fe31387: 3 PASS, exit 0.

## Criteria

1. AC1 `[test: make build]`: PASS. `make build` status success, 0 errors. 11 warnings, all in files that predate this branch (Capture.swift, HTTPServer.swift, MCPRequestHandler.swift, ServerController.swift:341); none in Reminders.swift or the package.
2. AC2 `[test: rkprobe all]`: PASS. `swift run rkprobe all` printed 8 PASS lines (ids, flagged, tag-remove, subtask-create, subtask-reparent, section-create, section-move, grocery).
3. AC3 `[test: e2e flag_create]`: PASS. Create returned flagged true with no warnings; get returned flagged true.
4. AC4 `[test: e2e flag_update]`: PASS. Update flagged false, then get returned flagged false.
5. AC5 `[test: e2e fetch_flagged_field]`: PASS. Fetch on "iMCP Tests" returned the created reminder's summary with flagged true.
6. AC6 `[test: ReminderKitBridgeTests.unavailableFrameworkReturnsWarning]`: PASS. Ran in the unit suite.
7. AC7 `[test: ReminderKitBridgeTests.flaggedRoundTrip]`: PASS. Ran in the unit suite.
8. AC8 `[manual]`: PASS. Joe confirmed "iMCP flag check (#36)" (EB36AE75-9BAA-4352-81AB-FB6D4B7C5757) shows flagged in Reminders.app on Mac and iPhone. Proxies AC3 and AC7 also passed.

Reconciliation: 8 criteria in the issue, 8 observed (5 named/build tests, 3 e2e, 1 manual; AC1 and AC2 counted once each), 8 passing.

## Go/no-go

Go. The signed, sandboxed app wrote through ReminderKit (AC3). No comment on #35 or blocked labels needed.

## Notes

1. Extra manual check (not a criterion): an EventKit-only title edit and a completion on a flagged reminder kept flagged true.
2. Workaround needed to build at all: swift-sdk bumped from revision 106167b to 0.12.1 (0c0afbd), because the old pin fails Swift 6.4.2 concurrency checks. Follow-up crash fix from upstream filed as #42.
