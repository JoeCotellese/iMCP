// ABOUTME: Live probes that verify ReminderKit features (flags, tags, subtasks, sections, grocery) on real data.
// ABOUTME: Creates test reminders through EventKit in dedicated "iMCP Probes" lists, then writes via ReminderKit.
//
// Usage: rkprobe all | ids | flagged | tag-remove | subtask-create | subtask-reparent | section-create | section-move | grocery

import EventKit
import Foundation
import ReminderKitBridge

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

let probeListName = "iMCP Probes"
let groceryListName = "iMCP Probes Grocery"
let sectionName = "Probe Section"

// MARK: - EventKit setup (the same public API iMCP uses to create reminders)

let ek = EKEventStore()

func requestAccess() throws {
    let group = DispatchGroup()
    var granted = false
    group.enter()
    ek.requestFullAccessToReminders { ok, _ in granted = ok; group.leave() }
    group.wait()
    if !granted { throw ProbeFailure(description: "Reminders access denied") }
}

func probeCalendar(named name: String) throws -> EKCalendar {
    if let existing = ek.calendars(for: .reminder).first(where: { $0.title == name }) { return existing }
    guard let source = ek.defaultCalendarForNewReminders()?.source else {
        throw ProbeFailure(description: "no default reminders source")
    }
    let calendar = EKCalendar(for: .reminder, eventStore: ek)
    calendar.title = name
    calendar.source = source
    try ek.saveCalendar(calendar, commit: true)
    return calendar
}

func makeReminder(_ title: String, in calendar: EKCalendar) throws -> EKReminder {
    let reminder = EKReminder(eventStore: ek)
    reminder.title = title
    reminder.calendar = calendar
    try ek.save(reminder, commit: true)
    return reminder
}

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HHmmss"
    return f.string(from: Date())
}

func remID(_ reminder: EKReminder) throws -> AnyObject {
    guard let uuid = UUID(uuidString: reminder.calendarItemIdentifier) else {
        throw ProbeFailure(description: "calendarItemIdentifier is not a UUID")
    }
    return try objectID("REMReminder", uuid: uuid)
}

func listID(_ calendar: EKCalendar) throws -> AnyObject {
    guard let uuid = UUID(uuidString: calendar.calendarIdentifier) else {
        throw ProbeFailure(description: "calendarIdentifier is not a UUID: \(calendar.calendarIdentifier)")
    }
    return try objectID("REMList", uuid: uuid)
}

func poll(seconds: Int, _ check: () throws -> Bool) rethrows -> Bool {
    for _ in 0..<seconds {
        if try check() { return true }
        Thread.sleep(forTimeInterval: 1)
    }
    return try check()
}

// MARK: - Probes

func probeIDs() throws -> String {
    let calendar = try probeCalendar(named: probeListName)
    let list = cast(try fetchList(try newStore(), try listID(calendar)), to: RList.self)
    guard list.displayName == probeListName else {
        throw ProbeFailure(description: "list name mismatch: \(list.displayName ?? "nil")")
    }
    return "EKCalendar.calendarIdentifier == REMList UUID (\(calendar.calendarIdentifier))"
}

func probeFlagged() throws -> String {
    let ekReminder = try makeReminder("probe-flagged-\(stamp())", in: try probeCalendar(named: probeListName))
    let id = try remID(ekReminder)
    let store = try newStore()
    let request = try newSaveRequest(store)
    let item = cast(request.updateReminder(try fetchReminder(store, id) as AnyObject), to: RReminderChangeItem.self)
    guard let flaggedContext = item.flaggedContext else { throw ProbeFailure(description: "no flaggedContext") }
    let flagged = cast(flaggedContext, to: RFlaggedContextChangeItem.self)
    flagged.flagged = 1
    try save(request)
    let after = try fetchReminder(try newStore(), id).flagged
    guard after == 1 else { throw ProbeFailure(description: "flagged read back as \(after)") }
    return "\(ekReminder.title!) flagged=1 read back"
}

func probeTagRemove() throws -> String {
    let ekReminder = try makeReminder("probe-tagremove-\(stamp())", in: try probeCalendar(named: probeListName))
    let id = try remID(ekReminder)

    let store = try newStore()
    let addRequest = try newSaveRequest(store)
    let addItem = cast(addRequest.updateReminder(try fetchReminder(store, id) as AnyObject), to: RReminderChangeItem.self)
    let addContext = cast(addItem.hashtagContext!, to: RHashtagContextChangeItem.self)
    _ = addContext.addHashtag(type: 0, name: "probekeep")
    _ = addContext.addHashtag(type: 0, name: "proberemove")
    try save(addRequest)
    let added = tagNames(try fetchReminder(try newStore(), id))
    guard added == ["probekeep", "proberemove"] else { throw ProbeFailure(description: "after add: \(added)") }

    let store2 = try newStore()
    let removeRequest = try newSaveRequest(store2)
    let removeItem = cast(removeRequest.updateReminder(try fetchReminder(store2, id) as AnyObject), to: RReminderChangeItem.self)
    let removeContext = cast(removeItem.hashtagContext!, to: RHashtagContextChangeItem.self)
    try requireSelector(removeContext as AnyObject, "removeHashtag:")
    guard let target = objects(in: removeContext.hashtags)
        .first(where: { cast($0, to: RHashtag.self).name == "proberemove" })
    else { throw ProbeFailure(description: "proberemove not in change item hashtags") }
    removeContext.removeHashtag(target)
    try save(removeRequest)
    let remaining = tagNames(try fetchReminder(try newStore(), id))
    guard remaining == ["probekeep"] else { throw ProbeFailure(description: "after remove: \(remaining)") }
    return "\(ekReminder.title!) tags \(added) -> \(remaining)"
}

func probeSubtaskCreate() throws -> String {
    let parent = try makeReminder("probe-parent-\(stamp())", in: try probeCalendar(named: probeListName))
    let parentID = try remID(parent)
    let store = try newStore()
    let request = try newSaveRequest(store)
    let item = cast(request.updateReminder(try fetchReminder(store, parentID) as AnyObject), to: RReminderChangeItem.self)
    guard let subtasks = item.subtaskContext else { throw ProbeFailure(description: "no subtaskContext") }
    let childTitle = "probe-child-of-\(parent.title!)"
    let child = cast(request.addReminder(title: childTitle, toSubtaskContext: subtasks), to: RReminderChangeItem.self)
    let childID = child.objectID
    try save(request)

    let fresh = try newStore()
    let readChild = try fetchReminder(fresh, childID)
    guard let readParent = readChild.parentReminderID, uuidOf(readParent) == uuidOf(parentID) else {
        throw ProbeFailure(description: "child parentReminderID mismatch")
    }
    ek.refreshSourcesIfNecessary()
    let visibleInEventKit = ek.calendarItem(withIdentifier: uuidOf(childID).uuidString) != nil
    return "\(childTitle) created under parent; visible to EventKit: \(visibleInEventKit)"
}

func probeSubtaskReparent() throws -> String {
    let calendar = try probeCalendar(named: probeListName)
    let s = stamp()
    let parent = try makeReminder("probe-reparent-parent-\(s)", in: calendar)
    let child = try makeReminder("probe-reparent-child-\(s)", in: calendar)
    let parentID = try remID(parent)
    let childID = try remID(child)
    let store = try newStore()
    let request = try newSaveRequest(store)
    let item = cast(request.updateReminder(try fetchReminder(store, childID) as AnyObject), to: RReminderChangeItem.self)
    item.parentReminderID = parentID
    try save(request)
    guard let readParent = try fetchReminder(try newStore(), childID).parentReminderID,
          uuidOf(readParent) == uuidOf(parentID)
    else { throw ProbeFailure(description: "parentReminderID not persisted") }
    return "\(child.title!) moved under \(parent.title!)"
}

func sections(in list: AnyObject, store: RStore) throws -> [RSection] {
    var error: NSError?
    guard let found = store.fetchListSections(listObjectID: list, error: &error) else {
        throw ProbeFailure(description: "fetch sections failed: \(error?.description ?? "nil")")
    }
    return objects(in: found).map { cast($0, to: RSection.self) }
}

func probeSectionCreate() throws -> String {
    let lid = try listID(try probeCalendar(named: probeListName))
    if let existing = try sections(in: lid, store: try newStore()).first(where: { $0.displayName == sectionName }) {
        return "\"\(sectionName)\" already exists (\(uuidOf(existing.objectID))); create path verified on an earlier run"
    }
    let store = try newStore()
    let request = try newSaveRequest(store)
    let listItem = cast(request.updateList(try fetchList(store, lid)), to: RListChangeItem.self)
    guard let sectionContext = listItem.sectionsContextChangeItem else {
        throw ProbeFailure(description: "no sectionsContextChangeItem")
    }
    _ = request.addListSection(displayName: sectionName, toSectionContext: sectionContext)
    try save(request)
    let names = try sections(in: lid, store: try newStore()).compactMap(\.displayName)
    guard names.contains(sectionName) else { throw ProbeFailure(description: "sections after save: \(names)") }
    return "created \"\(sectionName)\"; list sections: \(names)"
}

typealias MembershipInit = @convention(c) (AnyObject, Selector, NSUUID, NSUUID, Bool, NSDate) -> Unmanaged<AnyObject>?

func makeMemberships(reminder: UUID, section: UUID) throws -> AnyObject {
    let membershipClass = try requireClass("REMMembership")
    guard let allocated = (membershipClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
          let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
    else { throw ProbeFailure(description: "REMMembership alloc") }
    let initMembership = unsafeBitCast(msgSend, to: MembershipInit.self)
    let selector = NSSelectorFromString("initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:")
    guard let membership = initMembership(allocated, selector, reminder as NSUUID, section as NSUUID, false, Date() as NSDate)?
        .takeRetainedValue()
    else { throw ProbeFailure(description: "REMMembership init returned nil") }
    let byMember: NSDictionary = [reminder as NSUUID: membership]
    return try allocInit("REMMemberships", "initWithMembershipByMemberIdentifier:", byMember)
}

func sectionOf(reminder id: AnyObject) throws -> RSection? {
    let dataView = cast(try allocInit("REMListSectionsDataView", "initWithStore:", try newStore() as AnyObject),
                        to: RSectionsDataView.self)
    var error: NSError?
    return dataView.fetchListSection(reminderID: id, error: &error).map { cast($0, to: RSection.self) }
}

func probeSectionMove() throws -> String {
    let calendar = try probeCalendar(named: probeListName)
    let lid = try listID(calendar)
    guard let section = try sections(in: lid, store: try newStore()).first(where: { $0.displayName == sectionName }) else {
        throw ProbeFailure(description: "run section-create first")
    }
    let ekReminder = try makeReminder("probe-insection-\(stamp())", in: calendar)
    let rid = try remID(ekReminder)

    let store = try newStore()
    let request = try newSaveRequest(store)
    let listItem = cast(request.updateList(try fetchList(store, lid)), to: RListChangeItem.self)
    guard let sectionContext = listItem.sectionsContextChangeItem else {
        throw ProbeFailure(description: "no sectionsContextChangeItem")
    }
    let context = cast(sectionContext, to: RSectionContextChangeItem.self)
    context.memberships = try makeMemberships(reminder: uuidOf(rid), section: uuidOf(section.objectID))
    try save(request)

    guard let found = try sectionOf(reminder: rid) else {
        throw ProbeFailure(description: "fetchListSectionWithReminderID returned nil after save")
    }
    guard uuidOf(found.objectID) == uuidOf(section.objectID) else {
        throw ProbeFailure(description: "reminder landed in \(found.displayName ?? "?")")
    }
    return "\(ekReminder.title!) is in \"\(sectionName)\""
}

func probeGrocery() throws -> String {
    let calendar = try probeCalendar(named: groceryListName)
    let lid = try listID(calendar)

    var list = cast(try fetchList(try newStore(), lid), to: RList.self)
    if !list.shouldCategorizeGroceryItems {
        let store = try newStore()
        let request = try newSaveRequest(store)
        let listItem = cast(request.updateList(try fetchList(store, lid)), to: RListChangeItem.self)
        guard let groceryContext = listItem.groceryContextChangeItem else {
            throw ProbeFailure(description: "no groceryContextChangeItem")
        }
        let grocery = cast(groceryContext, to: RGroceryContextChangeItem.self)
        grocery.shouldCategorizeGroceryItems = true
        grocery.groceryLocaleID = Locale.current.identifier
        try save(request)
        list = cast(try fetchList(try newStore(), lid), to: RList.self)
        guard list.shouldCategorizeGroceryItems else { throw ProbeFailure(description: "grocery flag not persisted") }
    }
    print("    grocery list on, locale=\(list.groceryLocaleID ?? "nil")")

    let ekReminder = try makeReminder("Bananas", in: calendar)
    let rid = try remID(ekReminder)
    let passive = try poll(seconds: 30) { try sectionOf(reminder: rid) != nil }
    print("    EventKit-added item categorized without help: \(passive)")
    if passive {
        return "Bananas -> \(try sectionOf(reminder: rid)?.displayName ?? "?") with no trigger (daemon categorizes)"
    }

    let store = try newStore()
    let request = try newSaveRequest(store)
    let listItem = cast(request.updateList(try fetchList(store, lid)), to: RListChangeItem.self)
    let grocery = cast(listItem.groceryContextChangeItem!, to: RGroceryContextChangeItem.self)
    try requireSelector(grocery as AnyObject, "autoCategorizeRemindersWithReminderIDs:")
    grocery.autoCategorize(reminderIDs: [rid])
    try save(request)
    let triggered = try poll(seconds: 60) { try sectionOf(reminder: rid) != nil }
    guard triggered else { throw ProbeFailure(description: "not categorized 60s after explicit trigger") }
    return "Bananas -> \(try sectionOf(reminder: rid)?.displayName ?? "?") after autoCategorizeRemindersWithReminderIDs:"
}

// MARK: - Runner

let probes: [(String, () throws -> String)] = [
    ("ids", probeIDs),
    ("flagged", probeFlagged),
    ("tag-remove", probeTagRemove),
    ("subtask-create", probeSubtaskCreate),
    ("subtask-reparent", probeSubtaskReparent),
    ("section-create", probeSectionCreate),
    ("section-move", probeSectionMove),
    ("grocery", probeGrocery),
]

let selected = CommandLine.arguments.dropFirst().first ?? "all"
var failures = 0
do {
    try loadReminderKit()
    try requestAccess()
} catch {
    print("SETUP FAIL: \(error)")
    exit(2)
}
for (name, probe) in probes where selected == "all" || selected == name {
    do {
        print("PASS \(name): \(try probe())")
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}
exit(failures == 0 ? 0 : 1)
