// ABOUTME: Integration tests for ReminderKitBridge's public API against the live Reminders store.
// ABOUTME: Writes only to the "iMCP Tests" list and removes every reminder it creates.

import Foundation
import ReminderKitBridge
import Testing

@Suite struct ReminderKitBridgeTests {
    @Test func unavailableFrameworkReturnsWarning() async {
        let bridge = ReminderKitBridge(frameworkPath: "/nonexistent/ReminderKit.framework/ReminderKit")

        let result = await bridge.apply(ReminderEdit(flagged: true), reminder: UUID(), list: UUID())

        #expect(result.warnings.contains { $0.contains("ReminderKit unavailable") })
        #expect(result.extras.isEmpty)
    }
}
