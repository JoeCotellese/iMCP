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
    /// An empty edit only reads. `list` is the reminder's EventKit calendar identifier, for list-level edits.
    public func apply(_ edit: ReminderEdit, reminder: UUID, list: UUID) -> ApplyResult {
        do {
            try load()
        } catch {
            let warning = edit.isEmpty
                ? warning(for: error, fields: ReminderExtras.fieldNames, outcome: "not read")
                : warning(for: error, fields: edit.fieldNames, outcome: "not applied")
            return ApplyResult(warnings: [warning])
        }
        var warnings: [String] = []
        if !edit.isEmpty {
            do {
                warnings += try autoreleasepool { try write(edit, to: reminder) }
            } catch {
                warnings.append(warning(for: error, fields: edit.fieldNames, outcome: "not applied"))
            }
        }
        let readBack = read([reminder])
        return ApplyResult(extras: readBack.extras[reminder] ?? ReminderExtras(), warnings: warnings + readBack.warnings)
    }

    /// Reads the extras of each reminder with one fresh store. Reminders ReminderKit does not know are left out.
    public func read(_ reminders: [UUID]) -> ReadResult {
        guard !reminders.isEmpty else { return ReadResult() }
        do {
            try load()
            return ReadResult(extras: try autoreleasepool { try fetchExtras(reminders) })
        } catch {
            return ReadResult(warnings: [warning(for: error, fields: ReminderExtras.fieldNames, outcome: "not read")])
        }
    }

    private func load() throws {
        guard !isLoaded else { return }
        try loadReminderKit(path: frameworkPath)
        isLoaded = true
    }

    /// Builds one save request carrying every field of `edit` and saves it synchronously.
    /// Returns warnings for parts skipped without failing the save, such as removing a tag the reminder lacks.
    private func write(_ edit: ReminderEdit, to reminder: UUID) throws -> [String] {
        let store = try newStore()
        let request = try newSaveRequest(store)
        try requireSelector(request as AnyObject, "updateReminder:")
        let remReminder = try fetchReminder(store, try objectID("REMReminder", uuid: reminder))
        let item = cast(request.updateReminder(remReminder as AnyObject), to: RReminderChangeItem.self)

        if let flagged = edit.flagged {
            try requireSelector(item as AnyObject, "flaggedContext")
            guard let context = item.flaggedContext else { throw ReminderKitError.unsupportedAccount }
            try requireSelector(context, "setFlagged:")
            cast(context, to: RFlaggedContextChangeItem.self).flagged = flagged ? 1 : 0
        }

        let warnings = edit.hasTagChanges ? try writeTags(edit, item: item, reminder: remReminder) : []

        try save(request)
        return warnings
    }

    /// Adds and removes the tags `planTags` decides on, on the change item of an unsaved request.
    private func writeTags(_ edit: ReminderEdit, item: RReminderChangeItem, reminder: RReminder) throws -> [String] {
        try requireSelector(item as AnyObject, "accountCapabilities")
        guard let capabilities = item.accountCapabilities else {
            throw ReminderKitError.unexpectedNil("REMReminderChangeItem accountCapabilities")
        }
        try requireSelector(capabilities, "supportsHashtags")
        guard cast(capabilities, to: RAccountCapabilities.self).supportsHashtags else {
            return planTags(
                add: edit.addTags, remove: edit.removeTags, current: [],
                supportsHashtags: false, accountName: try accountName(of: reminder), sanitize: { $0 }
            ).warnings
        }

        try requireSelector(item as AnyObject, "hashtagContext")
        guard let contextObject = item.hashtagContext else {
            throw ReminderKitError.unexpectedNil("REMReminderChangeItem hashtagContext")
        }
        for selector in ["hashtags", "addHashtagWithType:name:", "removeHashtag:", "nameWithDisallowedCharactersReplaced:"] {
            try requireSelector(contextObject, selector)
        }
        let context = cast(contextObject, to: RHashtagContextChangeItem.self)
        let hashtags = objects(in: context.hashtags)
        let current = try hashtags.map {
            try requireSelector($0, "name")
            return cast($0, to: RHashtag.self).name
        }
        let plan = planTags(
            add: edit.addTags, remove: edit.removeTags, current: current,
            supportsHashtags: true, accountName: "", sanitize: { context.nameWithDisallowedCharactersReplaced($0) ?? $0 }
        )
        for name in plan.remove {
            if let index = current.firstIndex(of: name) { context.removeHashtag(hashtags[index]) }
        }
        for name in plan.add {
            _ = context.addHashtag(type: 0, name: name)
        }
        return plan.warnings
    }

    private func accountName(of reminder: RReminder) throws -> String {
        try requireSelector(reminder as AnyObject, "account")
        guard let account = reminder.account else { return "unknown" }
        try requireSelector(account, "displayName")
        return cast(account, to: RAccount.self).displayName ?? "unknown"
    }

    private func fetchExtras(_ reminders: [UUID]) throws -> [UUID: ReminderExtras] {
        let store = try newStore()
        try requireSelector(store as AnyObject, "fetchRemindersWithObjectIDs:error:")
        let ids = try reminders.map { try objectID("REMReminder", uuid: $0) }
        var error: NSError?
        guard let found = store.fetchReminders(objectIDs: ids as NSArray, error: &error) as? NSDictionary else {
            throw ReminderKitError.unexpectedNil("REMStore fetchRemindersWithObjectIDs:error: (\(error?.description ?? "no error"))")
        }
        var extras: [UUID: ReminderExtras] = [:]
        for (key, value) in found {
            let id = key as AnyObject
            let remReminder = value as AnyObject
            try requireSelector(id, "uuid")
            try requireSelector(remReminder, "flagged")
            let reminder = cast(remReminder, to: RReminder.self)
            extras[uuidOf(id)] = ReminderExtras(flagged: reminder.flagged != 0, tags: try tagNames(reminder))
        }
        return extras
    }

    /// Logs a ReminderKit failure and words it as a warning naming the fields it affected.
    private func warning(for error: Error, fields: [String], outcome: String) -> String {
        let fieldList = fields.joined(separator: ", ")
        switch error as? ReminderKitError {
        case .unavailable(let path):
            log.error("[ReminderKit] unavailable path=\(path, privacy: .public)")
            return "ReminderKit unavailable: \(fieldList) \(outcome)"
        case .classMissing(let name):
            log.error("[ReminderKit] selectorMissing \(name, privacy: .public) class")
            return "\(fieldList) \(outcome): unavailable on this macOS version"
        case .selectorMissing(let className, let selector):
            log.error("[ReminderKit] selectorMissing \(className, privacy: .public) \(selector, privacy: .public)")
            return "\(fieldList) \(outcome): unavailable on this macOS version"
        case .saveRejected(let reason):
            log.error("[ReminderKit] saveRejected \(reason)")
            return "\(fieldList) \(outcome): ReminderKit rejected the save"
        case .some(let other):
            log.error("[ReminderKit] \(other.description, privacy: .public)")
            return "\(fieldList) \(outcome): \(other.description)"
        case .none:
            log.error("[ReminderKit] \(error.localizedDescription, privacy: .public)")
            return "\(fieldList) \(outcome): \(error.localizedDescription)"
        }
    }
}
