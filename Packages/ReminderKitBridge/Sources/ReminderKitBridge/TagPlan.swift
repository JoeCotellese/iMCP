// ABOUTME: Decides which tags a ReminderKit write adds and removes, and which warnings it returns.
// ABOUTME: Pure function with no ReminderKit calls, so the account capability can be tested without such an account.

import Foundation

/// The tag operations one write performs. Names in `remove` are spelled as they are on the reminder.
package struct TagPlan: Sendable, Hashable {
    package var add: [String] = []
    package var remove: [String] = []
    package var warnings: [String] = []
}

/// Normalizes requested names (trim, strip leading `#`, sanitize, drop empty, dedupe ignoring case), then
/// matches them against the reminder's `current` tags ignoring case.
/// - Parameter sanitize: ReminderKit's `nameWithDisallowedCharactersReplaced:`, applied before deduping.
package func planTags(
    add: [String], remove: [String], current: [String],
    supportsHashtags: Bool, accountName: String, sanitize: (String) -> String
) -> TagPlan {
    guard !add.isEmpty || !remove.isEmpty else { return TagPlan() }
    guard supportsHashtags else {
        return TagPlan(warnings: ["tags not supported for account '\(accountName)'"])
    }
    var plan = TagPlan()
    for name in normalized(remove, sanitize) {
        if let existing = current.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            plan.remove.append(existing)
        } else {
            plan.warnings.append("tag '\(name)' not on reminder")
        }
    }
    let kept = current.filter { !plan.remove.contains($0) }
    plan.add = normalized(add, sanitize).filter { name in
        !kept.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
    return plan
}

private func normalized(_ names: [String], _ sanitize: (String) -> String) -> [String] {
    var result: [String] = []
    for raw in names {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix("#") { name.removeFirst() }
        name = sanitize(name)
        guard !name.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
        result.append(name)
    }
    return result
}
