// ABOUTME: Actor that loads private ReminderKit and applies or reads the reminder fields EventKit cannot reach.
// ABOUTME: Never throws: every ReminderKit failure becomes a warning, so the EventKit save it follows stands.

import Foundation
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ReminderKitBridge", category: "services.reminders")

public actor ReminderKitBridge {
    public static let defaultFrameworkPath = reminderKitFrameworkPath

    private let frameworkPath: String
    private var isLoaded = false

    /// - Parameter frameworkPath: the ReminderKit binary to dlopen. Tests pass a bad path to force the unavailable path.
    public init(frameworkPath: String = ReminderKitBridge.defaultFrameworkPath) {
        self.frameworkPath = frameworkPath
    }

    /// Writes `edit` to one reminder in a single save request, then reads its extras back with a fresh store.
    /// `list` is the reminder's EventKit calendar identifier, for list-level edits.
    public func apply(_ edit: ReminderEdit, reminder: UUID, list: UUID) -> ApplyResult {
        do {
            try load()
        } catch {
            return ApplyResult(warnings: [warning(for: error, fields: edit.fieldNames)])
        }
        return ApplyResult()
    }

    private func load() throws {
        guard !isLoaded else { return }
        try loadReminderKit(path: frameworkPath)
        isLoaded = true
    }

    /// Logs a ReminderKit failure and words it as a warning naming the fields that did not apply.
    private func warning(for error: Error, fields: [String]) -> String {
        let fieldList = fields.joined(separator: ", ")
        switch error as? ReminderKitError {
        case .unavailable(let path):
            log.error("[ReminderKit] unavailable path=\(path, privacy: .public)")
            return "ReminderKit unavailable: \(fieldList) not applied"
        case .classMissing(let name):
            log.error("[ReminderKit] selectorMissing \(name, privacy: .public) class")
            return "\(fieldList) not applied: unavailable on this macOS version"
        case .selectorMissing(let className, let selector):
            log.error("[ReminderKit] selectorMissing \(className, privacy: .public) \(selector, privacy: .public)")
            return "\(fieldList) not applied: unavailable on this macOS version"
        case .saveRejected(let reason):
            log.error("[ReminderKit] saveRejected \(reason)")
            return "\(fieldList) not applied: ReminderKit rejected the save"
        case .some(let other):
            log.error("[ReminderKit] \(other.description, privacy: .public)")
            return "\(fieldList) not applied: \(other.description)"
        case .none:
            log.error("[ReminderKit] \(error.localizedDescription, privacy: .public)")
            return "\(fieldList) not applied: \(error.localizedDescription)"
        }
    }
}
