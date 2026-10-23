// ABOUTME: Value types the bridge exchanges with iMCP: requested ReminderKit edits, extras read back, and warnings.
// ABOUTME: All are Sendable structs, so they cross from the bridge actor to the Reminders service freely.

import Foundation

/// ReminderKit-only fields to write on one reminder. A nil field is left untouched.
public struct ReminderEdit: Sendable, Hashable {
    public var flagged: Bool?
    /// Tag names to add. A leading `#` is stripped and case-only duplicates collapse.
    public var addTags: [String]
    /// Tag names to remove, matched ignoring case. A name the reminder lacks yields a warning.
    public var removeTags: [String]

    public init(flagged: Bool? = nil, addTags: [String] = [], removeTags: [String] = []) {
        self.flagged = flagged
        self.addTags = addTags
        self.removeTags = removeTags
    }

    public var isEmpty: Bool { fieldNames.isEmpty }

    var hasTagChanges: Bool { !addTags.isEmpty || !removeTags.isEmpty }

    /// Names of the fields this edit sets, for warnings that say what did not apply.
    var fieldNames: [String] {
        (flagged == nil ? [] : ["flagged"]) + (hasTagChanges ? ["tags"] : [])
    }
}

/// ReminderKit-only fields read back from one reminder. A nil field could not be read.
public struct ReminderExtras: Sendable, Hashable {
    public var flagged: Bool?
    /// Tag names on the reminder, sorted.
    public var tags: [String]?

    public init(flagged: Bool? = nil, tags: [String]? = nil) {
        self.flagged = flagged
        self.tags = tags
    }

    public var isEmpty: Bool { flagged == nil && tags == nil }

    /// Names of every field a read returns, for warnings when a read fails.
    static let fieldNames = ["flagged", "tags"]
}

/// Outcome of `ReminderKitBridge.apply`: the extras read back after the save, and what did not apply.
public struct ApplyResult: Sendable, Hashable {
    public var extras: ReminderExtras
    public var warnings: [String]

    public init(extras: ReminderExtras = ReminderExtras(), warnings: [String] = []) {
        self.extras = extras
        self.warnings = warnings
    }
}

/// Outcome of `ReminderKitBridge.read`: extras by reminder UUID, and why any could not be read.
public struct ReadResult: Sendable, Hashable {
    public var extras: [UUID: ReminderExtras]
    public var warnings: [String]

    public init(extras: [UUID: ReminderExtras] = [:], warnings: [String] = []) {
        self.extras = extras
        self.warnings = warnings
    }
}
