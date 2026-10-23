// ABOUTME: @objc protocol shims and helpers for calling private ReminderKit from Swift.
// ABOUTME: Selectors and types come from the ObjC runtime dumps recorded in REMINDERKIT.md.

import Foundation

// MARK: - Store and data views

@objc package protocol RStore {
    @objc(fetchReminderWithObjectID:error:)
    func fetchReminder(objectID: AnyObject, error: NSErrorPointer) -> AnyObject?
    @objc(fetchRemindersWithObjectIDs:error:)
    func fetchReminders(objectIDs: NSArray, error: NSErrorPointer) -> AnyObject?
    @objc(fetchListWithObjectID:error:)
    func fetchList(objectID: AnyObject, error: NSErrorPointer) -> AnyObject?
    @objc(fetchListSectionsWithListObjectID:error:)
    func fetchListSections(listObjectID: AnyObject, error: NSErrorPointer) -> NSArray?
    @objc(fetchRemindersWithParentReminderIDs:error:)
    func fetchReminders(parentIDs: NSArray, error: NSErrorPointer) -> AnyObject?
}

@objc package protocol RSectionsDataView {
    @objc(fetchListSectionWithReminderID:error:)
    func fetchListSection(reminderID: AnyObject, error: NSErrorPointer) -> AnyObject?
}

// MARK: - Read models

@objc package protocol RObjectID {
    @objc(uuid) var uuid: UUID { get }
}

@objc package protocol RReminder {
    @objc(objectID) var objectID: AnyObject { get }
    @objc(titleAsString) var titleAsString: String? { get }
    @objc(hashtagContext) var hashtagContext: AnyObject? { get }
    @objc(flagged) var flagged: Int { get }
    @objc(parentReminderID) var parentReminderID: AnyObject? { get }
    @objc(account) var account: AnyObject? { get }
}

@objc package protocol RAccount {
    @objc(displayName) var displayName: String? { get }
}

@objc package protocol RAccountCapabilities {
    @objc(supportsHashtags) var supportsHashtags: Bool { get }
}

@objc package protocol RHashtagContext {
    @objc(hashtags) var hashtags: AnyObject? { get }
}

@objc package protocol RHashtag {
    @objc(name) var name: String { get }
    @objc(type) var tagType: Int { get }
}

@objc package protocol RList {
    @objc(objectID) var objectID: AnyObject { get }
    @objc(displayName) var displayName: String? { get }
    @objc(shouldCategorizeGroceryItems) var shouldCategorizeGroceryItems: Bool { get }
    @objc(groceryLocaleID) var groceryLocaleID: String? { get }
    @objc(shouldAutoCategorizeItems) var shouldAutoCategorizeItems: Bool { get }
}

@objc package protocol RSection {
    @objc(objectID) var objectID: AnyObject { get }
    @objc(displayName) var displayName: String? { get }
    @objc(canonicalName) var canonicalName: String? { get }
}

// MARK: - Save request and change items

@objc package protocol RSaveRequest {
    @objc(updateReminder:) func updateReminder(_ reminder: AnyObject) -> AnyObject
    @objc(updateList:) func updateList(_ list: AnyObject) -> AnyObject
    @objc(addReminderWithTitle:toReminderSubtaskContextChangeItem:)
    func addReminder(title: String, toSubtaskContext: AnyObject) -> AnyObject
    @objc(addListSectionWithDisplayName:toListSectionContextChangeItem:)
    func addListSection(displayName: String, toSectionContext: AnyObject) -> AnyObject
    @objc(saveSynchronouslyWithError:) func saveSynchronously(error: NSErrorPointer) -> Bool
}

@objc package protocol RReminderChangeItem {
    @objc(objectID) var objectID: AnyObject { get }
    @objc(hashtagContext) var hashtagContext: AnyObject? { get }
    @objc(flaggedContext) var flaggedContext: AnyObject? { get }
    @objc(subtaskContext) var subtaskContext: AnyObject? { get }
    @objc(accountCapabilities) var accountCapabilities: AnyObject? { get }
    @objc(parentReminderID) var parentReminderID: AnyObject? { get set }
}

@objc package protocol RHashtagContextChangeItem {
    @objc(hashtags) var hashtags: AnyObject? { get }
    @objc(addHashtagWithType:name:) func addHashtag(type: Int, name: String) -> AnyObject?
    @objc(removeHashtag:) func removeHashtag(_ hashtag: AnyObject)
    @objc(nameWithDisallowedCharactersReplaced:) func nameWithDisallowedCharactersReplaced(_ name: String) -> String?
}

@objc package protocol RFlaggedContextChangeItem {
    @objc(flagged) var flagged: Int { get set }
}

@objc package protocol RListChangeItem {
    @objc(sectionsContextChangeItem) var sectionsContextChangeItem: AnyObject? { get }
    @objc(groceryContextChangeItem) var groceryContextChangeItem: AnyObject? { get }
}

@objc package protocol RSectionContextChangeItem {
    @objc(unsavedMembershipsOfRemindersInSections) var memberships: AnyObject? { get set }
}

@objc package protocol RGroceryContextChangeItem {
    @objc(shouldCategorizeGroceryItems) var shouldCategorizeGroceryItems: Bool { get set }
    @objc(groceryLocaleID) var groceryLocaleID: String? { get set }
    @objc(autoCategorizeRemindersWithReminderIDs:) func autoCategorize(reminderIDs: NSArray)
}

// MARK: - Helpers

package let reminderKitFrameworkPath = "/System/Library/PrivateFrameworks/ReminderKit.framework/Versions/A/ReminderKit"

package func cast<T>(_ object: AnyObject, to: T.Type) -> T { unsafeBitCast(object, to: T.self) }

package func loadReminderKit(path: String = reminderKitFrameworkPath) throws {
    guard dlopen(path, RTLD_NOW) != nil else { throw ReminderKitError.unavailable(path: path) }
}

package func requireClass(_ name: String) throws -> NSObject.Type {
    guard let cls = NSClassFromString(name) as? NSObject.Type else {
        throw ReminderKitError.classMissing(name)
    }
    return cls
}

/// Fails with a clear message instead of crashing when a selector disappears in a future macOS.
package func requireSelector(_ object: AnyObject, _ selector: String) throws {
    guard object.responds(to: NSSelectorFromString(selector)) else {
        throw ReminderKitError.selectorMissing(className: String(describing: type(of: object)), selector: selector)
    }
}

/// alloc + one-argument initializer for classes whose only useful init takes an object.
package func allocInit(_ className: String, _ initSelector: String, _ arg: AnyObject) throws -> AnyObject {
    let cls = try requireClass(className)
    guard cls.instancesRespond(to: NSSelectorFromString(initSelector)) else {
        throw ReminderKitError.selectorMissing(className: className, selector: initSelector)
    }
    // An init returns +1, so take ownership of its result; taking it unretained leaks one object per call.
    guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
          let object = allocated.perform(NSSelectorFromString(initSelector), with: arg)?.takeRetainedValue()
    else { throw ReminderKitError.unexpectedNil("\(className) \(initSelector)") }
    return object
}

package func objectID(_ className: String, uuid: UUID) throws -> AnyObject {
    let cls = try requireClass(className)
    let selector = NSSelectorFromString("objectIDWithUUID:")
    guard cls.responds(to: selector) else {
        throw ReminderKitError.selectorMissing(className: className, selector: "objectIDWithUUID:")
    }
    guard let id = cls.perform(selector, with: uuid)?.takeUnretainedValue()
    else { throw ReminderKitError.unexpectedNil("\(className) objectIDWithUUID:") }
    return id
}

package func newStore() throws -> RStore {
    cast(try requireClass("REMStore").init(), to: RStore.self)
}

package func newSaveRequest(_ store: RStore) throws -> RSaveRequest {
    cast(try allocInit("REMSaveRequest", "initWithStore:", store as AnyObject), to: RSaveRequest.self)
}

package func save(_ request: RSaveRequest) throws {
    try requireSelector(request as AnyObject, "saveSynchronouslyWithError:")
    var error: NSError?
    guard request.saveSynchronously(error: &error) else {
        throw ReminderKitError.saveRejected(error?.description ?? "no error")
    }
}

package func fetchReminder(_ store: RStore, _ id: AnyObject) throws -> RReminder {
    try requireSelector(store as AnyObject, "fetchReminderWithObjectID:error:")
    var error: NSError?
    guard let r = store.fetchReminder(objectID: id, error: &error) else {
        throw ReminderKitError.notFound(uuidOf(id))
    }
    return cast(r, to: RReminder.self)
}

package func fetchList(_ store: RStore, _ id: AnyObject) throws -> AnyObject {
    try requireSelector(store as AnyObject, "fetchListWithObjectID:error:")
    var error: NSError?
    guard let l = store.fetchList(objectID: id, error: &error) else {
        throw ReminderKitError.notFound(uuidOf(id))
    }
    return l
}

package func objects(in collection: AnyObject?) -> [AnyObject] {
    if let set = collection as? NSSet { return set.allObjects as [AnyObject] }
    if let array = collection as? NSArray { return array as [AnyObject] }
    if let ordered = collection as? NSOrderedSet { return ordered.array as [AnyObject] }
    return []
}

/// Sorted tag names on a reminder. Throws instead of crashing when a hashtag selector disappears.
package func tagNames(_ reminder: RReminder) throws -> [String] {
    try requireSelector(reminder as AnyObject, "hashtagContext")
    guard let context = reminder.hashtagContext else { return [] }
    try requireSelector(context, "hashtags")
    return try objects(in: cast(context, to: RHashtagContext.self).hashtags).map {
        try requireSelector($0, "name")
        return cast($0, to: RHashtag.self).name
    }.sorted()
}

package func uuidOf(_ objectID: AnyObject) -> UUID { cast(objectID, to: RObjectID.self).uuid }
