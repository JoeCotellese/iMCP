<!-- ABOUTME: Definition of Done results for #44, the Pontemac rebrand. -->
<!-- ABOUTME: Records each acceptance criterion's channel, outcome, and evidence. -->

# DoD results: #44 Pontemac rebrand

1. Date: 2026-10-22 14:20 EDT
2. Branch: `feature/44-pontemac-rebrand`
3. Commit: `43bdbcd`
4. Status: PASS (12/12 criteria)
5. Unit: `xcodebuild test -project iMCP.xcodeproj -scheme iMCP -only-testing:iMCPTests`: 2 tests in 1 suite passed, TEST SUCCEEDED.
6. Acceptance: `scripts/e2e-branding.sh` after `make install`, with /Applications/iMCP.app also running: ALL PASS (10/10). `--self-test` also passes.
7. Screenshots: none. The AXe harness is iOS Simulator only; the About window and menu bar extra were checked by hand (AC4, AC5).

## Criteria

1. AC1 `[test: e2e-branding bundle_layout]`: PASS. `/Applications/Pontemac.app` contains an executable `Contents/MacOS/pontemac-server`.
2. AC2 `[test: e2e-branding bundle_id]`: PASS. `CFBundleIdentifier` is `com.joecotellese.pontemac` (amended from `me.cotellese.Pontemac` with Joe's approval; issue comment of 2026-10-22).
3. AC3 `[test: e2e-branding info_plist]`: PASS. No `SU*` keys; `NSHumanReadableCopyright` is `© 2026 Joe Cotellese`.
4. AC4 `[manual]`: PASS. Joe confirmed the menu bar title and "About Pontemac". Proxy `bundle_name` PASS.
5. AC5 `[manual]`: PASS. Joe confirmed contents, links, keyboard focus and Cmd-W. Proxy `about_contract` PASS.
6. AC6 `[manual]`: PASS. Joe confirmed `dns-sd -B _pontemac._tcp` lists Pontemac in Bonjour mode. Proxy `bonjour_type` PASS.
7. AC7 `[test: e2e-branding server_info]`: PASS. `initialize` through `pontemac-server` returned `serverInfo.name == "Pontemac"` with iMCP running. iMCP listens on 9847, Pontemac on 9848.
8. AC8 `[test: ClaudeDesktopConfigMergeTests.testReplacesOwnedIMCPEntry]`: PASS. Mutation (no removal) fails it.
9. AC9 `[test: ClaudeDesktopConfigMergeTests.testKeepsForeignIMCPEntry]`: PASS. Mutation (ignore command suffix) fails it.
10. AC10 `[test: e2e-branding source_strings]`: PASS. Allowlist amended with Joe's approval to include `legacyServerKey = "iMCP"`.
11. AC11 `[test: e2e-branding license]`: PASS.
12. AC12 `[test: e2e-branding reminders_default]`: PASS.

Reconciliation: 12 criteria = 9 automated (7 e2e-branding, 2 unit) + 3 manual.

## Findings during implementation

1. AC7 first failed for a real bug: `HTTPServer.start()` confirmed its bind by GETting `/health`, which iMCP answered on 9847, so Pontemac advertised iMCP's port. Fixed in `90a46e0` (Hummingbird `onServerRunning`).
2. The CLI read the unsandboxed `Application Support/iMCP/transport.json` first; a stale copy pointed at iMCP. Removed in `224948b` with Joe's approval.
3. AC8 and AC10 conflicted as written; caught at /implement, not /ready. Candidate for /retro.
