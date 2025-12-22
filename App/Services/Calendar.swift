import AppKit
import CoreLocation
import EventKit
import Foundation
import MCP
import OSLog
import Ontology

private let log = Logger.service("calendar")

/// Converts an EKEvent to a Value object with identifier for MCP responses
private func eventToValue(_ event: EKEvent) -> Value {
    var dict: [String: Value] = [
        "identifier": .string(event.eventIdentifier),
        "title": .string(event.title ?? ""),
        "start": .string(ISO8601DateFormatter().string(from: event.startDate)),
        "end": .string(ISO8601DateFormatter().string(from: event.endDate)),
        "isAllDay": .bool(event.isAllDay),
        "calendar": .string(event.calendar?.title ?? ""),
        "availability": .string(event.availability.stringValue),
        "hasRecurrenceRules": .bool(event.hasRecurrenceRules),
    ]

    if let location = event.location, !location.isEmpty {
        dict["location"] = .string(location)
    }

    if let notes = event.notes, !notes.isEmpty {
        dict["notes"] = .string(notes)
    }

    if let url = event.url {
        dict["url"] = .string(url.absoluteString)
    }

    if let creationDate = event.creationDate {
        dict["createdAt"] = .string(ISO8601DateFormatter().string(from: creationDate))
    }

    if let lastModifiedDate = event.lastModifiedDate {
        dict["modifiedAt"] = .string(ISO8601DateFormatter().string(from: lastModifiedDate))
    }

    if let alarms = event.alarms, !alarms.isEmpty {
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

final class CalendarService: Service {
    private let eventStore = EKEventStore()

    static let shared = CalendarService()

    var isActivated: Bool {
        get async {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
    }

    func activate() async throws {
        try await eventStore.requestFullAccessToEvents()
    }

    var tools: [Tool] {
        Tool(
            name: "calendars_list",
            description: "List available calendars",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Calendars",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            let calendars = self.eventStore.calendars(for: .event)

            return calendars.map { calendar in
                Value.object([
                    "title": .string(calendar.title),
                    "source": .string(calendar.source.title),
                    "color": .string(calendar.color.accessibilityName),
                    "isEditable": .bool(calendar.allowsContentModifications),
                    "isSubscribed": .bool(calendar.isSubscribed),
                ])
            }
        }

        Tool(
            name: "events_fetch",
            description: "Get events from the calendar with flexible filtering options",
            inputSchema: .object(
                properties: [
                    "start": .string(
                        description: "Start date of the range (defaults to now)",
                        format: .dateTime
                    ),
                    "end": .string(
                        description: "End date of the range (defaults to one week from start)",
                        format: .dateTime
                    ),
                    "calendars": .array(
                        description:
                            "Names of calendars to fetch from; if empty, fetches from all calendars",
                        items: .string(),
                    ),
                    "query": .string(
                        description: "Text to search for in event titles and locations"
                    ),
                    "includeAllDay": .boolean(
                        default: true
                    ),
                    "status": .string(
                        description: "Filter by event status",
                        enum: ["none", "tentative", "confirmed", "canceled"]
                    ),
                    "availability": .string(
                        description: "Filter by availability status",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "hasAlarms": .boolean(),
                    "isRecurring": .boolean(),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Events",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Filter calendars based on provided names
            var calendars = self.eventStore.calendars(for: .event)
            if case let .array(calendarNames) = arguments["calendars"],
                !calendarNames.isEmpty
            {
                let requestedNames = Set(calendarNames.compactMap { $0.stringValue?.lowercased() })
                calendars = calendars.filter { requestedNames.contains($0.title.lowercased()) }
            }

            // Parse dates and set defaults
            let now = Date()
            var startDate = now
            var endDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: now)!

            if case let .string(start) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parseFlexibleISODate(start)
            {
                startDate = parsedStart
            }

            if case let .string(end) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parseFlexibleISODate(end)
            {
                endDate = parsedEnd
            }

            // Create base predicate for date range and calendars
            let predicate = self.eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: calendars
            )

            // Fetch events
            var events = self.eventStore.events(matching: predicate)

            // Apply additional filters
            if case let .bool(includeAllDay) = arguments["includeAllDay"],
                !includeAllDay
            {
                events = events.filter { !$0.isAllDay }
            }

            if case let .string(searchText) = arguments["query"],
                !searchText.isEmpty
            {
                events = events.filter {
                    ($0.title?.localizedCaseInsensitiveContains(searchText) == true)
                        || ($0.location?.localizedCaseInsensitiveContains(searchText) == true)
                }
            }

            if case let .string(status) = arguments["status"] {
                let statusValue = EKEventStatus(status)
                events = events.filter { $0.status == statusValue }
            }

            if case let .string(availability) = arguments["availability"] {
                let availabilityValue = EKEventAvailability(availability)
                events = events.filter { $0.availability == availabilityValue }
            }

            if case let .bool(hasAlarms) = arguments["hasAlarms"] {
                events = events.filter { ($0.hasAlarms) == hasAlarms }
            }

            if case let .bool(isRecurring) = arguments["isRecurring"] {
                events = events.filter { ($0.hasRecurrenceRules) == isRecurring }
            }

            return events.map { eventToValue($0) }
        }
        Tool(
            name: "events_create",
            description: "Create a new calendar event with specified properties",
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "start": .string(
                        format: .dateTime
                    ),
                    "end": .string(
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Calendar to use (uses default if not specified)"
                    ),
                    "location": .string(),
                    "notes": .string(),
                    "url": .string(
                        format: .uri
                    ),
                    "isAllDay": .boolean(
                        default: false
                    ),
                    "availability": .string(
                        description: "Availability status",
                        default: .string(EKEventAvailability.busy.stringValue),
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Alarm configurations for the event",
                        items: .anyOf(
                            [
                                // Relative alarm (minutes before event)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "relative",
                                        ),
                                        "minutes": .integer(
                                            description:
                                                "Minutes offset from event start (negative for before, positive for after)"
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["minutes"],
                                    additionalProperties: false
                                ),
                                // Absolute alarm (specific date/time)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "absolute",
                                        ),
                                        "datetime": .string(
                                            format: .dateTime
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["datetime"],
                                    additionalProperties: false
                                ),
                                // Proximity alarm (location-based)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "proximity",
                                        ),
                                        "proximity": .string(
                                            description: "Proximity trigger type",
                                            default: "enter",
                                            enum: ["enter", "leave"]
                                        ),
                                        "locationTitle": .string(),
                                        "latitude": .number(),
                                        "longitude": .number(),
                                        "radius": .number(
                                            description: "Radius in meters",
                                            default: .int(200)
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send notification to"
                                        ),
                                    ],
                                    required: ["locationTitle", "latitude", "longitude"],
                                    additionalProperties: false
                                ),
                            ]
                        )
                    ),
                    "hasAlarms": .boolean(),
                    "isRecurring": .boolean(),
                ],
                required: ["title", "start", "end"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Create new event
            let event = EKEvent(eventStore: self.eventStore)

            // Set required properties
            guard case let .string(title) = arguments["title"] else {
                throw NSError(
                    domain: "CalendarError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event title is required"]
                )
            }
            event.title = title

            // Parse dates
            guard case let .string(startDateStr) = arguments["start"],
                let startDate = ISO8601DateFormatter.parseFlexibleISODate(startDateStr),
                case let .string(endDateStr) = arguments["end"],
                let endDate = ISO8601DateFormatter.parseFlexibleISODate(endDateStr)
            else {
                throw NSError(
                    domain: "CalendarError", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid start or end date format. Expected ISO 8601 format."
                    ]
                )
            }

            // For all-day events, ensure we use local midnight
            if case .bool(true) = arguments["isAllDay"] {
                let calendar = Calendar.current
                var startComponents = calendar.dateComponents(
                    [.year, .month, .day], from: startDate)
                startComponents.hour = 0
                startComponents.minute = 0
                startComponents.second = 0

                var endComponents = calendar.dateComponents([.year, .month, .day], from: endDate)
                endComponents.hour = 23
                endComponents.minute = 59
                endComponents.second = 59

                event.startDate = calendar.date(from: startComponents)!
                event.endDate = calendar.date(from: endComponents)!
                event.isAllDay = true
            } else {
                event.startDate = startDate
                event.endDate = endDate
            }

            // Set calendar
            var calendar = self.eventStore.defaultCalendarForNewEvents
            if case let .string(calendarName) = arguments["calendar"] {
                if let matchingCalendar = self.eventStore.calendars(for: .event)
                    .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                {
                    calendar = matchingCalendar
                }
            }
            event.calendar = calendar

            // Set optional properties
            if case let .string(location) = arguments["location"] {
                event.location = location
            }

            if case let .string(notes) = arguments["notes"] {
                event.notes = notes
            }

            if case let .string(urlString) = arguments["url"],
                let url = URL(string: urlString)
            {
                event.url = url
            }

            if case let .string(availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            // Set alarms
            if case let .array(alarmConfigs) = arguments["alarms"] {
                var alarms: [EKAlarm] = []

                for alarmConfig in alarmConfigs {
                    guard case let .object(config) = alarmConfig else { continue }

                    var alarm: EKAlarm?

                    let alarmType = config["type"]?.stringValue ?? "relative"
                    switch alarmType {
                    case "relative":
                        if case let .int(minutes) = config["minutes"] {
                            alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                        }

                    case "absolute":
                        if case let .string(datetimeStr) = config["datetime"],
                            let absoluteDate = ISO8601DateFormatter.parseFlexibleISODate(
                                datetimeStr)
                        {
                            alarm = EKAlarm(absoluteDate: absoluteDate)
                        }

                    case "proximity":
                        if case let .string(locationTitle) = config["locationTitle"],
                            case let .double(latitude) = config["latitude"],
                            case let .double(longitude) = config["longitude"]
                        {
                            alarm = EKAlarm()

                            // Create structured location
                            let structuredLocation = EKStructuredLocation(title: locationTitle)
                            structuredLocation.geoLocation = CLLocation(
                                latitude: latitude, longitude: longitude)

                            if case let .double(radius) = config["radius"] {
                                structuredLocation.radius = radius
                            } else if case let .int(radiusInt) = config["radius"] {
                                structuredLocation.radius = Double(radiusInt)
                            }

                            // Set proximity type
                            let proximityType = config["proximity"]?.stringValue ?? "enter"
                            let proximity: EKAlarmProximity =
                                proximityType == "enter" ? .enter : .leave
                            alarm?.proximity = proximity
                            alarm?.structuredLocation = structuredLocation
                        }

                    default:
                        log.error("Unexpected alarm type encountered: \(alarmType, privacy: .public)")
                        continue
                    }

                    guard let alarm = alarm else { continue }

                    if case let .string(soundName) = config["sound"],
                        Sound(rawValue: soundName) != nil
                    {
                        alarm.soundName = soundName
                    }

                    if case let .string(email) = config["emailAddress"], !email.isEmpty {
                        alarm.emailAddress = email
                    }

                    alarms.append(alarm)
                }

                event.alarms = alarms
            }

            // Save the event
            try self.eventStore.save(event, span: .thisEvent)

            return eventToValue(event)
        }

        Tool(
            name: "events_get",
            description: "Fetch a single calendar event by its identifier",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "The unique identifier of the event"
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Event",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            guard case let .string(identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "CalendarError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event identifier is required"]
                )
            }

            guard let event = self.eventStore.event(withIdentifier: identifier) else {
                throw NSError(
                    domain: "CalendarError", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found with identifier: \(identifier)"]
                )
            }

            return eventToValue(event)
        }

        Tool(
            name: "events_update",
            description: "Update an existing calendar event's properties",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "The unique identifier of the event to update"
                    ),
                    "title": .string(
                        description: "New title for the event"
                    ),
                    "start": .string(
                        description: "New start date/time (ISO 8601 format)",
                        format: .dateTime
                    ),
                    "end": .string(
                        description: "New end date/time (ISO 8601 format)",
                        format: .dateTime
                    ),
                    "location": .string(
                        description: "New location for the event"
                    ),
                    "notes": .string(
                        description: "New notes for the event"
                    ),
                    "url": .string(
                        description: "New URL for the event",
                        format: .uri
                    ),
                    "calendar": .string(
                        description: "Move event to a different calendar"
                    ),
                    "availability": .string(
                        description: "New availability status",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Replace alarms (minutes before event start)",
                        items: .integer()
                    ),
                    "span": .string(
                        description: "For recurring events: thisEvent (default) or futureEvents",
                        default: "thisEvent",
                        enum: EKSpan.allCases.map { .string($0.stringValue) }
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            guard case let .string(identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "CalendarError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event identifier is required"]
                )
            }

            guard let event = self.eventStore.event(withIdentifier: identifier) else {
                throw NSError(
                    domain: "CalendarError", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found with identifier: \(identifier)"]
                )
            }

            guard event.calendar.allowsContentModifications else {
                throw NSError(
                    domain: "CalendarError", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar '\(event.calendar.title)' is read-only"]
                )
            }

            // Update title if provided
            if case let .string(title) = arguments["title"] {
                event.title = title
            }

            // Update dates if provided, with validation
            var newStart = event.startDate!
            var newEnd = event.endDate!

            if case let .string(startStr) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parseFlexibleISODate(startStr)
            {
                newStart = parsedStart
            }

            if case let .string(endStr) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parseFlexibleISODate(endStr)
            {
                newEnd = parsedEnd
            }

            // Validate date consistency
            if newEnd < newStart {
                throw NSError(
                    domain: "CalendarError", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "End date must be after start date"]
                )
            }

            event.startDate = newStart
            event.endDate = newEnd

            // Update location if provided
            if case let .string(location) = arguments["location"] {
                event.location = location
            }

            // Update notes if provided
            if case let .string(notes) = arguments["notes"] {
                event.notes = notes
            }

            // Update URL if provided
            if case let .string(urlString) = arguments["url"] {
                event.url = URL(string: urlString)
            }

            // Move to different calendar if provided
            if case let .string(calendarName) = arguments["calendar"] {
                guard let matchingCalendar = self.eventStore.calendars(for: .event)
                    .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                else {
                    let availableCalendars = self.eventStore.calendars(for: .event)
                        .map { $0.title }.joined(separator: ", ")
                    throw NSError(
                        domain: "CalendarError", code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Calendar '\(calendarName)' not found. Available: \(availableCalendars)"]
                    )
                }
                guard matchingCalendar.allowsContentModifications else {
                    throw NSError(
                        domain: "CalendarError", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Target calendar '\(matchingCalendar.title)' is read-only"]
                    )
                }
                event.calendar = matchingCalendar
            }

            // Update availability if provided
            if case let .string(availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            // Replace alarms if provided
            if case let .array(alarmMinutes) = arguments["alarms"] {
                event.alarms = alarmMinutes.compactMap {
                    guard case let .int(minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
            }

            // Determine span for recurring events
            let span: EKSpan
            if case let .string(spanStr) = arguments["span"] {
                span = EKSpan(spanStr)
            } else {
                span = .thisEvent
            }

            try self.eventStore.save(event, span: span)

            return eventToValue(event)
        }

        Tool(
            name: "events_delete",
            description: "Delete a calendar event",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "The unique identifier of the event to delete"
                    ),
                    "span": .string(
                        description: "For recurring events: thisEvent (default) or futureEvents",
                        default: "thisEvent",
                        enum: EKSpan.allCases.map { .string($0.stringValue) }
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            guard case let .string(identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "CalendarError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event identifier is required"]
                )
            }

            guard let event = self.eventStore.event(withIdentifier: identifier) else {
                throw NSError(
                    domain: "CalendarError", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found with identifier: \(identifier)"]
                )
            }

            guard event.calendar.allowsContentModifications else {
                throw NSError(
                    domain: "CalendarError", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar '\(event.calendar.title)' is read-only"]
                )
            }

            // Capture event details before deletion for response
            let deletedInfo = eventToValue(event)

            // Determine span for recurring events
            let span: EKSpan
            if case let .string(spanStr) = arguments["span"] {
                span = EKSpan(spanStr)
            } else {
                span = .thisEvent
            }

            try self.eventStore.remove(event, span: span)

            return deletedInfo
        }
    }
}
