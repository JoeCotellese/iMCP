// ABOUTME: Errors raised when the private ReminderKit framework, one of its classes, or a selector is missing.
// ABOUTME: The bridge turns each one into a warning so a ReminderKit failure never fails an EventKit write.

import Foundation

public enum ReminderKitError: Error, Sendable, Equatable, CustomStringConvertible {
    /// dlopen of the framework failed.
    case unavailable(path: String)
    /// A ReminderKit class no longer exists on this macOS version.
    case classMissing(String)
    /// A ReminderKit object no longer responds to a selector the bridge calls.
    case selectorMissing(className: String, selector: String)
    /// The reminder's account does not support the feature (for example, CalDAV lists have no flags).
    case unsupportedAccount
    /// No ReminderKit object matches the identifier.
    case notFound(UUID)
    /// remindd refused the save request.
    case saveRejected(String)
    /// A ReminderKit call that should return an object returned nil.
    case unexpectedNil(String)

    public var description: String {
        switch self {
        case .unavailable(let path): "ReminderKit unavailable at \(path)"
        case .classMissing(let name): "class \(name) not found"
        case .selectorMissing(let className, let selector): "\(className) no longer responds to \(selector)"
        case .unsupportedAccount: "the reminder's account does not support this"
        case .notFound(let uuid): "no ReminderKit object with ID \(uuid.uuidString)"
        case .saveRejected(let reason): "save rejected: \(reason)"
        case .unexpectedNil(let call): "\(call) returned nil"
        }
    }
}
