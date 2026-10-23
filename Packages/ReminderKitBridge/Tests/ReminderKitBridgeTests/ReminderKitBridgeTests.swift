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

    @Test func tagsRoundTrip() async throws {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        try #require(granted, "grant Reminders access to the terminal running swift test")
        let list = try #require(
            store.calendars(for: .reminder).first { $0.title == testListName },
            "create a reminder list named \"\(testListName)\""
        )
        let reminder = EKReminder(eventStore: store)
        reminder.title = "ReminderKitBridgeTests tagsRoundTrip"
        reminder.calendar = list
        try store.save(reminder, commit: true)
        defer { try? store.remove(reminder, commit: true) }
        let reminderID = try #require(UUID(uuidString: reminder.calendarItemIdentifier))
        let listID = try #require(UUID(uuidString: list.calendarIdentifier))
        // A per-run suffix keeps tags from earlier runs from satisfying the assertions.
        let suffix = String(Int(Date().timeIntervalSince1970))
        let keep = "keep\(suffix)"
        let drop = "drop\(suffix)"

        let added = await ReminderKitBridge().apply(ReminderEdit(addTags: [keep, drop]), reminder: reminderID, list: listID)
        #expect(added.warnings.isEmpty)
        #expect(added.extras.tags == [drop, keep])

        let removed = await ReminderKitBridge().apply(ReminderEdit(removeTags: [drop]), reminder: reminderID, list: listID)
        #expect(removed.warnings.isEmpty)

        let read = await ReminderKitBridge().read([reminderID])
        #expect(read.extras[reminderID]?.tags == [keep])

        _ = await ReminderKitBridge().apply(ReminderEdit(removeTags: [keep]), reminder: reminderID, list: listID)
    }

    @Test func unsupportedAccountSkipsTags() {
        let plan = planTags(
            add: ["errands"], remove: ["home"], current: ["home"],
            supportsHashtags: false, accountName: "Exchange", sanitize: { $0 }
        )

        #expect(plan.add.isEmpty)
        #expect(plan.remove.isEmpty)
        #expect(plan.warnings == ["tags not supported for account 'Exchange'"])
    }

    @Test func normalizesTagNames() {
        let plan = planTags(
            add: ["#errands", "Errands", " my tag ", "mytag", "#", ""], remove: [], current: [],
            supportsHashtags: true, accountName: "iCloud", sanitize: { $0.replacingOccurrences(of: " ", with: "") }
        )

        #expect(plan.add == ["errands", "mytag"])
        #expect(plan.warnings.isEmpty)
    }

    @Test func unavailableFrameworkReturnsWarning() async {
        let bridge = ReminderKitBridge(frameworkPath: "/nonexistent/ReminderKit.framework/ReminderKit")

        let result = await bridge.apply(ReminderEdit(flagged: true), reminder: UUID(), list: UUID())

        #expect(result.warnings.contains { $0.contains("ReminderKit unavailable") })
        #expect(result.extras.isEmpty)
    }

    @Test func unavailableFrameworkReadOnlyApplyNamesReadFields() async {
        let bridge = ReminderKitBridge(frameworkPath: "/nonexistent/ReminderKit.framework/ReminderKit")

        let result = await bridge.apply(ReminderEdit(), reminder: UUID(), list: UUID())

        #expect(result.warnings == ["ReminderKit unavailable: flagged, tags not read"])
    }
}
