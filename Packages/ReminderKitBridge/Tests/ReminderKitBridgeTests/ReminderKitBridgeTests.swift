// ABOUTME: Integration tests for ReminderKitBridge's public API against the live Reminders store.
// ABOUTME: Writes only to the "iMCP Tests" list and removes every reminder it creates.

import EventKit
import Foundation
import ReminderKitBridge
import Testing

private let testListName = "iMCP Tests"

@Suite struct ReminderKitBridgeTests {
    @Test func flaggedRoundTrip() async throws {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        try #require(granted, "grant Reminders access to the terminal running swift test")
        let list = try #require(
            store.calendars(for: .reminder).first { $0.title == testListName },
            "create a reminder list named \"\(testListName)\""
        )
        let reminder = EKReminder(eventStore: store)
        reminder.title = "ReminderKitBridgeTests flaggedRoundTrip"
        reminder.calendar = list
        try store.save(reminder, commit: true)
        defer { try? store.remove(reminder, commit: true) }
        let reminderID = try #require(UUID(uuidString: reminder.calendarItemIdentifier))
        let listID = try #require(UUID(uuidString: list.calendarIdentifier))

        let applied = await ReminderKitBridge().apply(ReminderEdit(flagged: true), reminder: reminderID, list: listID)
        #expect(applied.warnings.isEmpty)

        let read = await ReminderKitBridge().read([reminderID])
        #expect(read.extras[reminderID]?.flagged == true)
    }

    @Test func unavailableFrameworkReturnsWarning() async {
        let bridge = ReminderKitBridge(frameworkPath: "/nonexistent/ReminderKit.framework/ReminderKit")

        let result = await bridge.apply(ReminderEdit(flagged: true), reminder: UUID(), list: UUID())

        #expect(result.warnings.contains { $0.contains("ReminderKit unavailable") })
        #expect(result.extras.isEmpty)
    }
}
