import EventKit
import Foundation
import MCP
import OSLog
import Ontology

private let log = Logger.service("reminders")

/// Converts an EKReminder to a Value object with identifier for MCP responses
private func reminderToValue(_ reminder: EKReminder) -> Value {
    var dict: [String: Value] = [
        "identifier": .string(reminder.calendarItemIdentifier),
        "title": .string(reminder.title ?? ""),
        "isCompleted": .bool(reminder.isCompleted),
        "priority": .string(EKReminderPriority(rawValue: UInt(reminder.priority))?.stringValue ?? "none"),
        "list": .string(reminder.calendar?.title ?? ""),
    ]

    if let notes = reminder.notes, !notes.isEmpty {
        dict["notes"] = .string(notes)
    }

    if let dueDateComponents = reminder.dueDateComponents,
        let dueDate = Calendar.current.date(from: dueDateComponents)
    {
        dict["due"] = .string(ISO8601DateFormatter().string(from: dueDate))
    }

    if let completionDate = reminder.completionDate {
        dict["completedAt"] = .string(ISO8601DateFormatter().string(from: completionDate))
    }

    if let creationDate = reminder.creationDate {
        dict["createdAt"] = .string(ISO8601DateFormatter().string(from: creationDate))
    }

    if let lastModifiedDate = reminder.lastModifiedDate {
        dict["modifiedAt"] = .string(ISO8601DateFormatter().string(from: lastModifiedDate))
    }

    if let alarms = reminder.alarms, !alarms.isEmpty {
        dict["alarms"] = .array(alarms.compactMap { alarm -> Value? in
            if let absoluteDate = alarm.absoluteDate {
                return .object([
                    "type": .string("absolute"),
                    "datetime": .string(ISO8601DateFormatter().string(from: absoluteDate))
                ])
            } else {
                let minutes = Int(-alarm.relativeOffset / 60)
                return .object([
                    "type": .string("relative"),
                    "minutes": .int(minutes)
                ])
            }
        })
    }

    return .object(dict)
}

final class RemindersService: Service {
    private let eventStore = EKEventStore()

    static let shared = RemindersService()

    var isActivated: Bool {
        get async {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
    }

    func activate() async throws {
        try await eventStore.requestFullAccessToReminders()
    }

    var tools: [Tool] {
        Tool(
            name: "reminders_lists",
            description: "List available reminder lists",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Reminder Lists",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminderLists = self.eventStore.calendars(for: .reminder)

            return reminderLists.map { reminderList in
                Value.object([
                    "title": .string(reminderList.title),
                    "source": .string(reminderList.source.title),
                    "color": .string(reminderList.color.accessibilityName),
                    "isEditable": .bool(reminderList.allowsContentModifications),
                    "isSubscribed": .bool(reminderList.isSubscribed),
                ])
            }
        }

        Tool(
            name: "reminders_fetch",
            description: "Get reminders from the reminders app with flexible filtering options",
            inputSchema: .object(
                properties: [
                    "completed": .boolean(
                        description:
                            "If true, fetch completed reminders; if false, fetch incomplete; if omitted, fetch all"
                    ),
                    "start": .string(
                        description: "Start date range for fetching reminders",
                        format: .dateTime
                    ),
                    "end": .string(
                        description: "End date range for fetching reminders",
                        format: .dateTime
                    ),
                    "lists": .array(
                        description:
                            "Names of reminder lists to fetch from; if empty, fetches from all lists",
                        items: .string()
                    ),
                    "query": .string(
                        description: "Text to search for in reminder titles"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Reminders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            // Filter reminder lists based on provided names
            var reminderLists = self.eventStore.calendars(for: .reminder)
            if case let .array(listNames) = arguments["lists"],
                !listNames.isEmpty
            {
                let requestedNames = Set(
                    listNames.compactMap { $0.stringValue?.lowercased() })
                let filteredLists = reminderLists.filter {
                    requestedNames.contains($0.title.lowercased())
                }
                if filteredLists.isEmpty {
                    let availableLists = reminderLists.map { $0.title }.joined(separator: ", ")
                    let requested = requestedNames.joined(separator: ", ")
                    throw NSError(
                        domain: "RemindersError", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "No matching lists found for: \(requested). Available lists: \(availableLists)"]
                    )
                }
                reminderLists = filteredLists
            }

            // Parse dates if provided
            var startDate: Date? = nil
            var endDate: Date? = nil

            if case let .string(start) = arguments["start"] {
                startDate = ISO8601DateFormatter.parseFlexibleISODate(start)
            }
            if case let .string(end) = arguments["end"] {
                endDate = ISO8601DateFormatter.parseFlexibleISODate(end)
            }

            // Create predicate based on completion status
            // Handle bool, int (JSON false=0, true=1), and string representations
            let predicate: NSPredicate
            let completedArg = arguments["completed"]
            let completedValue: Bool?
            switch completedArg {
            case .bool(let value):
                completedValue = value
            case .int(let value):
                completedValue = (value != 0)
            case .string(let str):
                switch str.lowercased() {
                case "true": completedValue = true
                case "false": completedValue = false
                default: completedValue = nil
                }
            default:
                completedValue = nil
            }

            log.debug("reminders_fetch: completed arg=\(String(describing: completedArg)), parsed=\(String(describing: completedValue))")

            if let completed = completedValue {
                if completed {
                    predicate = self.eventStore.predicateForCompletedReminders(
                        withCompletionDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    )
                } else {
                    predicate = self.eventStore.predicateForIncompleteReminders(
                        withDueDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    )
                }
            } else {
                // If completion status not specified, fetch all reminders
                predicate = self.eventStore.predicateForReminders(in: reminderLists)
            }

            // Fetch reminders
            let reminders = try await withCheckedThrowingContinuation { continuation in
                self.eventStore.fetchReminders(matching: predicate) { fetchedReminders in
                    continuation.resume(returning: fetchedReminders ?? [])
                }
            }

            // Apply additional filters
            var filteredReminders = reminders

            // Filter by search text if provided
            if case let .string(searchText) = arguments["query"],
                !searchText.isEmpty
            {
                filteredReminders = filteredReminders.filter {
                    $0.title?.localizedCaseInsensitiveContains(searchText) == true
                }
            }

            return filteredReminders.map { reminderToValue($0) }
        }

        Tool(
            name: "reminders_create",
            description: "Create a new reminder with specified properties",
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "due": .string(
                        format: .dateTime
                    ),
                    "list": .string(
                        description: "Reminder list name (uses default if not specified)"
                    ),
                    "notes": .string(),
                    "priority": .string(
                        default: .string(EKReminderPriority.none.stringValue),
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Minutes before due date to set alarms",
                        items: .integer()
                    ),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminder = EKReminder(eventStore: self.eventStore)

            // Set required properties
            guard case let .string(title) = arguments["title"] else {
                throw NSError(
                    domain: "RemindersError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder title is required"]
                )
            }
            reminder.title = title

            // Set calendar (list)
            var calendar = self.eventStore.defaultCalendarForNewReminders()
            if case let .string(listName) = arguments["list"] {
                if let matchingCalendar = self.eventStore.calendars(for: .reminder)
                    .first(where: { $0.title.lowercased() == listName.lowercased() })
                {
                    calendar = matchingCalendar
                }
            }
            reminder.calendar = calendar

            // Set optional properties
            if case let .string(dueDateStr) = arguments["due"],
                let dueDate = ISO8601DateFormatter.parseFlexibleISODate(dueDateStr)
            {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: dueDate)
            }

            if case let .string(notes) = arguments["notes"] {
                reminder.notes = notes
            }

            if case let .string(priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            // Set alarms
            if case let .array(alarmMinutes) = arguments["alarms"] {
                reminder.alarms = alarmMinutes.compactMap {
                    guard case let .int(minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
            }

            // Save the reminder
            try self.eventStore.save(reminder, commit: true)

            return reminderToValue(reminder)
        }

        Tool(
            name: "reminders_get",
            description: "Fetch a single reminder by its identifier",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "The unique identifier of the reminder"
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Reminder",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case let .string(identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "RemindersError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder identifier is required"]
                )
            }

            guard let item = self.eventStore.calendarItem(withIdentifier: identifier),
                let reminder = item as? EKReminder
            else {
                throw NSError(
                    domain: "RemindersError", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder not found with identifier: \(identifier)"]
                )
            }

            return reminderToValue(reminder)
        }

        Tool(
            name: "reminders_complete",
            description: "Mark one or more reminders as completed or incomplete",
            inputSchema: .object(
                properties: [
                    "identifiers": .array(
                        description: "The unique identifiers of the reminders to update",
                        items: .string()
                    ),
                    "completed": .boolean(
                        description: "Set to true to mark as completed, false to mark as incomplete",
                        default: true
                    )
                ],
                required: ["identifiers"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Complete Reminders",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case let .array(identifierValues) = arguments["identifiers"],
                !identifierValues.isEmpty
            else {
                throw NSError(
                    domain: "RemindersError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "At least one reminder identifier is required"]
                )
            }

            let identifiers = identifierValues.compactMap { $0.stringValue }
            let completed = arguments["completed"]?.boolValue ?? true

            var updatedReminders: [EKReminder] = []

            for identifier in identifiers {
                guard let item = self.eventStore.calendarItem(withIdentifier: identifier),
                    let reminder = item as? EKReminder
                else {
                    log.warning("Reminder not found: \(identifier, privacy: .public)")
                    continue
                }

                reminder.isCompleted = completed
                try self.eventStore.save(reminder, commit: false)
                updatedReminders.append(reminder)
            }

            try self.eventStore.commit()

            return updatedReminders.map { reminderToValue($0) }
        }

        Tool(
            name: "reminders_update",
            description: "Update an existing reminder's properties",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "The unique identifier of the reminder to update"
                    ),
                    "title": .string(
                        description: "New title for the reminder"
                    ),
                    "due": .string(
                        description: "New due date (ISO 8601 format), or null to clear",
                        format: .dateTime
                    ),
                    "notes": .string(
                        description: "New notes for the reminder"
                    ),
                    "list": .string(
                        description: "Move reminder to a different list"
                    ),
                    "priority": .string(
                        description: "New priority level",
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Replace alarms with new ones (minutes before due date)",
                        items: .integer()
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case let .string(identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "RemindersError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder identifier is required"]
                )
            }

            guard let item = self.eventStore.calendarItem(withIdentifier: identifier),
                let reminder = item as? EKReminder
            else {
                throw NSError(
                    domain: "RemindersError", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder not found with identifier: \(identifier)"]
                )
            }

            guard reminder.calendar.allowsContentModifications else {
                throw NSError(
                    domain: "RemindersError", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder list '\(reminder.calendar.title)' is read-only"]
                )
            }

            // Update title if provided
            if case let .string(title) = arguments["title"] {
                reminder.title = title
            }

            // Update due date if provided
            if let dueValue = arguments["due"] {
                if case let .string(dueDateStr) = dueValue,
                    let dueDate = ISO8601DateFormatter.parseFlexibleISODate(dueDateStr)
                {
                    reminder.dueDateComponents = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second], from: dueDate)
                } else if case .null = dueValue {
                    reminder.dueDateComponents = nil
                }
            }

            // Update notes if provided
            if case let .string(notes) = arguments["notes"] {
                reminder.notes = notes
            }

            // Move to different list if provided
            if case let .string(listName) = arguments["list"] {
                guard let matchingCalendar = self.eventStore.calendars(for: .reminder)
                    .first(where: { $0.title.lowercased() == listName.lowercased() })
                else {
                    throw NSError(
                        domain: "RemindersError", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "List '\(listName)' not found"]
                    )
                }
                guard matchingCalendar.allowsContentModifications else {
                    throw NSError(
                        domain: "RemindersError", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Target list '\(matchingCalendar.title)' is read-only"]
                    )
                }
                reminder.calendar = matchingCalendar
            }

            // Update priority if provided
            if case let .string(priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            // Replace alarms if provided
            if case let .array(alarmMinutes) = arguments["alarms"] {
                reminder.alarms = alarmMinutes.compactMap {
                    guard case let .int(minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
            }

            try self.eventStore.save(reminder, commit: true)

            return reminderToValue(reminder)
        }

        Tool(
            name: "reminders_delete",
            description: "Delete a reminder",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "The unique identifier of the reminder to delete"
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case let .string(identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "RemindersError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder identifier is required"]
                )
            }

            guard let item = self.eventStore.calendarItem(withIdentifier: identifier),
                let reminder = item as? EKReminder
            else {
                throw NSError(
                    domain: "RemindersError", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder not found with identifier: \(identifier)"]
                )
            }

            guard reminder.calendar.allowsContentModifications else {
                throw NSError(
                    domain: "RemindersError", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder list '\(reminder.calendar.title)' is read-only"]
                )
            }

            // Capture reminder details before deletion for response
            let deletedInfo = reminderToValue(reminder)

            try self.eventStore.remove(reminder, commit: true)

            return deletedInfo
        }
    }
}
