// ABOUTME: Value types the bridge exchanges with iMCP: requested ReminderKit edits, extras read back, and warnings.
// ABOUTME: All are Sendable structs, so they cross from the bridge actor to the Reminders service freely.

import Foundation

/// ReminderKit-only fields to write on one reminder. A nil field is left untouched.
public struct ReminderEdit: Sendable, Hashable {
    public var flagged: Bool?

    public init(flagged: Bool? = nil) {
        self.flagged = flagged
    }

    public var isEmpty: Bool { fieldNames.isEmpty }

    /// Names of the fields this edit sets, for warnings that say what did not apply.
    var fieldNames: [String] {
        flagged == nil ? [] : ["flagged"]
    }
}

/// ReminderKit-only fields read back from one reminder. A nil field could not be read.
public struct ReminderExtras: Sendable, Hashable {
    public var flagged: Bool?

    public init(flagged: Bool? = nil) {
        self.flagged = flagged
    }

    public var isEmpty: Bool { flagged == nil }

    /// Names of every field a read returns, for warnings when a read fails.
    static let fieldNames = ["flagged"]
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
