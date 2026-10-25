import CryptoKit
import DesignSystem
import Foundation
import SpaceCrypto
import SpaceModel
import SpacePlanning
import Testing
import UserNotifications
@testable import Features

@MainActor
private final class ReminderCenter: SpaceNotificationCenter {
    var status = UNAuthorizationStatus.authorized
    var permissionRequests = 0
    var categories: [UNNotificationCategory] = []
    var requests: [String: UNNotificationRequest] = [:]
    var notices: [String: UNNotificationRequest] = [:]
    var adds = 0
    var whenCheckingStatus: () -> Void = {}
    var whenAuthorizing: () -> Void = {}
    var whenAdding: () -> Void = {}
    var pauseAuthorization: (@MainActor () async -> Void)?
    var pauseAdd: (@MainActor () async -> Void)?
    func authorizationStatus() async -> UNAuthorizationStatus { whenCheckingStatus(); return status }
    func requestAuthorization() async throws -> Bool {
        permissionRequests += 1
        whenAuthorizing()
        await pauseAuthorization?()
        status = .authorized
        return true
    }
    func registerCategory(_ category: UNNotificationCategory) async { categories = [category] }
    var reads = 0
    var whenReading: () -> Void = {}
    func pending() async -> [UNNotificationRequest] { reads += 1; whenReading(); return Array(requests.values) }
    func delivered() async -> [UNNotificationRequest] { Array(notices.values) }
    func add(_ request: UNNotificationRequest) async throws {
        adds += 1
        requests[request.identifier] = request
        whenAdding()
        await pauseAdd?()
    }
    func withdraw(_ identifiers: [String]) {
        for id in identifiers { requests[id] = nil; notices[id] = nil }
    }
    func fire() { notices = requests; requests = [:] }
}

@MainActor
private final class ReminderGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}

@MainActor
struct SpaceReminderTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-25T08:00:00Z")!
    let zone = TimeZone(identifier: "Europe/Paris")!
    let parent = PageID(), item = PageID()

    func pages(timed: Bool = true) throws -> [PageID: PageRecord] {
        let due = try DateValue(start: DatePoint(timed ? "2026-10-26T09:00" : "2026-10-26"),
                                tz: timed ? "Australia/Melbourne" : nil, remind: .before(15))
        return [parent: PageRecord(order: try OrderKey("a"), title: "Groceries", created: 0),
                item: PageRecord(parent: parent, order: try OrderKey("a"), title: "Buy milk",
                                 props: [FieldID.due: .date(due), FieldID.done: .checkbox(false)], created: 0)]
    }
    private func controller(_ store: SpacePageStore, _ center: ReminderCenter) -> SpaceReminderController {
        SpaceReminderController(store: store, center: center, clock: { now }, zone: { zone }, automaticWakes: false)
    }

    @Test func mapsPlannerOutputToCalendarRequestAndLocalizedContent() throws {
        for timed in [true, false] {
            let pages = try pages(timed: timed)
            let planned = try #require(ReminderPlanner.plan(pages: pages, now: now, deviceTimeZone: zone).first)
            let request = SpaceReminderNotification.request(planned, stamp: "digest", locale: Locale(identifier: "en_GB"))
            let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
            #expect(request.identifier == planned.id)
            #expect(trigger.dateComponents == planned.components)
            #expect(!trigger.repeats)
            #expect(trigger.dateComponents.timeZone?.identifier == (timed ? "Australia/Melbourne" : nil))
            #expect(request.content.title == "Buy milk")
            #expect(request.content.body == (timed ? "23:00" : "09:00"), "the parent's title never goes in")
            #expect(request.content.categoryIdentifier == SpaceReminderNotification.categoryID)
            #expect(request.content.userInfo["pageID"] as? String == item.rawValue)
            #expect(request.content.userInfo["stamp"] as? String == "digest")
            #expect(request.content.sound != nil)
        }
        let category = SpaceReminderNotification.category
        #expect(category.actions.map(\.title) == ["Mark done", "Snooze 10 min"])
        #expect(!category.actions[0].options.contains(.foreground))
        #expect(!category.options.contains(.customDismissAction))
    }

    @Test func startupReplacesChangedRequestsWithoutDuplicatingAndPreservesThreadNotices() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        let sut = controller(store, center)
        let thread = UNNotificationRequest(identifier: "thread.completed", content: UNMutableNotificationContent(), trigger: nil)
        center.requests[thread.identifier] = thread; center.notices[thread.identifier] = thread
        sut.setEnabled(true); await sut.settle()
        let old = try #require(center.requests.values.first { SpaceReminderNotification.owns($0.identifier) })
        #expect(center.adds == 1)
        sut.refresh(); await sut.settle()
        #expect(center.adds == 1)
        store.rename(item, "Buy oat milk"); await sut.settle()
        #expect(center.requests[old.identifier]?.content.title == "Buy oat milk")
        #expect(center.adds == 2 && center.requests.count == 2)
        sut.setEnabled(false); await sut.settle()
        #expect(center.requests.keys.sorted() == [thread.identifier])
        #expect(center.notices.keys.sorted() == [thread.identifier])
    }

    @Test func requestsScheduledWithTheParentTitleAreReplacedOrWithdrawn() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        let sut = controller(store, center)
        sut.setEnabled(true); await sut.settle()
        let current = try #require(center.requests.values.first)
        // What an earlier build scheduled: the parent's title in the body, under that build's digest of the
        // unchanged item and its parent's title, which stays valid unless the digest itself changed.
        var data = try SpaceJSON.encode(store.pages[item]!)
        data.append(try SpaceJSON.encode("Groceries"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func old(_ id: String) -> UNNotificationRequest {
            let content = current.content.mutableCopy() as! UNMutableNotificationContent
            content.body = "Groceries · 23:00"
            var info = content.userInfo
            info["stamp"] = digest
            content.userInfo = info
            return UNNotificationRequest(identifier: id, content: content, trigger: current.trigger)
        }
        center.requests[current.identifier] = old(current.identifier)
        center.requests[current.identifier + ".snooze"] = old(current.identifier + ".snooze")
        center.notices[current.identifier] = old(current.identifier)
        let next = controller(store, center)
        next.setEnabled(true); await next.settle()
        #expect(center.requests.keys.sorted() == [current.identifier])
        #expect(center.requests[current.identifier]?.content.body == "23:00")
        #expect(center.notices.isEmpty)
        #expect(!center.requests.values.contains { $0.content.body.contains("Groceries") })
        sut.setEnabled(false); next.setEnabled(false); await sut.settle(); await next.settle()
    }

    @Test func offLaunchTouchesNotificationsOnlyForLeftovers() async throws {
        let defaults = try #require(UserDefaults(suiteName: "SpaceReminderTests.\(UUID().uuidString)"))
        let settings = SpaceSettings(defaults: defaults)
        let center = ReminderCenter()
        let left = UNNotificationRequest(identifier: "space.left", content: UNMutableNotificationContent(), trigger: nil)
        let thread = UNNotificationRequest(identifier: "thread.completed", content: UNMutableNotificationContent(), trigger: nil)
        center.requests = [left.identifier: left, thread.identifier: thread]
        // A normal off launch: nothing scheduled earlier, so no notification call at all.
        await SpaceReminderController.withdrawLeftovers(settings: settings, center: center)
        #expect(center.reads == 0 && center.requests.count == 2)
        // A run that quit before its withdrawal finished left reminders behind: withdraw them once.
        settings.remindersScheduled = true
        await SpaceReminderController.withdrawLeftovers(settings: settings, center: center)
        #expect(center.requests.keys.sorted() == [thread.identifier])
        #expect(!settings.remindersScheduled)
        await SpaceReminderController.withdrawLeftovers(settings: settings, center: center)
        #expect(center.reads == 1)
    }

    @Test func offLaunchCleanupLeavesRemindersAloneWhenSpaceTurnsOnMeanwhile() async throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let defaults = try #require(UserDefaults(suiteName: "SpaceReminderTests.\(UUID().uuidString)"))
        let settings = SpaceSettings(defaults: defaults)
        settings.remindersScheduled = true
        let center = ReminderCenter()
        let fresh = UNNotificationRequest(identifier: "space.fresh", content: UNMutableNotificationContent(), trigger: nil)
        center.requests[fresh.identifier] = fresh
        // The switch goes on while the cleanup waits on the notification center.
        center.whenReading = { settings.enabled = true }
        await SpaceReminderController.withdrawLeftovers(settings: settings, center: center)
        #expect(center.requests[fresh.identifier] != nil, "the new controller's reminder stays")
        #expect(settings.remindersScheduled)
    }

    @Test func withdrawingAnOldDeliveredVersionKeepsTheCurrentPendingVersion() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        let sut = controller(store, center)
        sut.setEnabled(true); await sut.settle()
        let old = try #require(center.requests.values.first)
        store.rename(item, "New title"); await sut.settle()
        let current = try #require(center.requests[old.identifier])
        center.notices[old.identifier] = old
        sut.refresh(); await sut.settle()
        #expect(center.notices.isEmpty)
        #expect(center.requests[old.identifier] == current)
        sut.setEnabled(false); await sut.settle()
    }

    @Test func dateChangeDoneDeleteAndAncestorTrashWithdrawPendingAndDelivered() async throws {
        for change in 0..<5 {
            let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
            let sut = controller(store, center)
            sut.setEnabled(true); await sut.settle()
            let old = try #require(center.requests.values.first)
            center.notices[old.identifier] = old
            switch change {
            case 0:
                var record = store.pages[item]!
                record.props[FieldID.due] = .date(try DateValue(start: DatePoint("2026-10-27"), remind: .before(0)))
                store.put([item: record])
            case 1:
                var record = store.pages[item]!; record.props[FieldID.done] = .checkbox(true); store.put([item: record])
            case 2: store.remove(item)
            case 3: store.trash(parent)
            default:
                var record = store.pages[item]!; record.props[FieldID.due] = nil; store.put([item: record])
            }
            await sut.settle()
            #expect(center.requests[old.identifier] == nil && center.notices[old.identifier] == nil)
            #expect(center.requests.count == (change == 0 ? 1 : 0))
            sut.setEnabled(false); await sut.settle()
        }
    }

    @Test func unchangedDeliveredSurvivesRelaunchButRenameAndDisableWithdrawIt() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        let first = controller(store, center)
        first.setEnabled(true); await first.settle()
        center.fire()
        let old = try #require(center.notices.values.first)
        let next = SpaceReminderController(store: store, center: center, clock: { now.addingTimeInterval(172800) },
                                           zone: { zone }, automaticWakes: false)
        next.setEnabled(true); await next.settle()
        #expect(center.notices[old.identifier] != nil)
        store.rename(parent, "Shopping"); await next.settle(); await first.settle()
        #expect(center.notices[old.identifier] != nil, "the parent's title isn't in the notification")
        store.rename(item, "Buy oat milk"); await next.settle(); await first.settle()
        #expect(center.notices.isEmpty)
        first.setEnabled(false); next.setEnabled(false); await first.settle(); await next.settle()
        // Off on cold launch clears even unknown Space ids, without reading a local copy.
        center.notices[old.identifier] = old; center.requests[old.identifier] = old
        let off = controller(InMemorySpacePageStore(), center)
        off.setEnabled(false); await off.settle()
        #expect(center.notices.isEmpty && center.requests.isEmpty)
    }

    @Test func openDoneAndStaleActionsUseTheCurrentStore() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        let sut = controller(store, center)
        var opened: PageID?, flushed = false
        sut.openPage = { opened = $0 }; sut.flush = { flushed = true }
        sut.setEnabled(true); await sut.settle()
        let request = try #require(center.requests.values.first)
        await sut.respond(to: request, action: UNNotificationDefaultActionIdentifier)
        #expect(opened == item && !flushed)
        center.notices[request.identifier] = request
        await sut.respond(to: request, action: SpaceReminderNotification.doneAction)
        #expect(store.pages[item]?.props[FieldID.done] == .checkbox(true) && flushed)
        #expect(center.requests.isEmpty && center.notices.isEmpty)
        opened = nil
        await sut.respond(to: request, action: UNNotificationDefaultActionIdentifier)
        #expect(opened == nil)
        sut.setEnabled(false); await sut.settle()
    }

    @Test func doneIsDurableThroughTheEncryptedApplyPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = SpaceKeyStore.inMemory(), store = PersistentSpacePageStore(), center = ReminderCenter()
        _ = try await store.open(applicationSupport: directory, keyStore: keys)
        store.put(try pages())
        let sut = controller(store, center)
        sut.flush = { try await store.flush() }
        sut.setEnabled(true); await sut.settle()
        let request = try #require(center.requests.values.first)
        let response = try #require(SpaceReminderResponse(request: request, action: SpaceReminderNotification.doneAction))
        await sut.respond(to: response)
        #expect(!store.isSaving && store.failure == nil)
        sut.setEnabled(false); await sut.settle(); try await store.close()
        _ = try await store.open(applicationSupport: directory, keyStore: keys)
        #expect(store.pages[item]?.props[FieldID.done] == .checkbox(true))
        try await store.close()
    }

    @Test func snoozeStaysOnThisDeviceSurvivesReplanningAndWithdrawsOnEdit() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        let sut = controller(store, center)
        sut.setEnabled(true); await sut.settle()
        let request = try #require(center.requests.values.first)
        await sut.respond(to: request, action: SpaceReminderNotification.snoozeAction)
        let snooze = try #require(center.requests[request.identifier + ".snooze"])
        #expect((snooze.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 600)
        #expect(store.pages[item]?.props[FieldID.done] == .checkbox(false))
        await sut.respond(to: snooze, action: SpaceReminderNotification.snoozeAction)
        #expect(center.requests[snooze.identifier] != nil)
        let next = controller(store, center)
        next.setEnabled(true); await next.settle()
        #expect(center.requests[snooze.identifier] != nil)
        store.rename(item, "Edited"); await sut.settle(); await next.settle()
        #expect(center.requests[snooze.identifier] == nil)
        sut.setEnabled(false); next.setEnabled(false); await sut.settle(); await next.settle()
    }

    @Test func permissionIsLazyAndDisableDuringAuthorizationCannotLeaveARequest() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore()
        center.status = .notDetermined
        let sut = controller(store, center)
        sut.setEnabled(true); await sut.settle()
        #expect(center.permissionRequests == 0)
        center.whenCheckingStatus = { sut.setEnabled(false) }
        store.put(try pages()); await sut.settle()
        #expect(center.permissionRequests == 0 && center.requests.isEmpty)
        center.whenCheckingStatus = {}
        center.whenAuthorizing = { sut.setEnabled(false) }
        sut.setEnabled(true); await sut.settle()
        #expect(center.permissionRequests == 1 && center.requests.isEmpty)
        center.whenAuthorizing = {}
        sut.setEnabled(true); await sut.settle()
        #expect(center.requests.count == 1)
        center.whenAdding = { sut.setEnabled(false) }
        store.rename(item, "Changed during add"); await sut.settle()
        #expect(center.requests.isEmpty)
    }

    @Test func firstReminderAsksPermissionEvenBeyondThePlanningWindow() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        center.status = .notDetermined
        var record = store.pages[item]!
        record.props[FieldID.due] = .date(try DateValue(start: DatePoint("2027-02-01"), remind: .before(0)))
        store.put([item: record])
        let sut = controller(store, center)
        sut.setEnabled(true); await sut.settle()
        #expect(center.permissionRequests == 1 && center.requests.isEmpty)
        sut.setEnabled(false); await sut.settle()
    }

    @Test func quitWaitsForSchedulingAndWithdrawal() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        let sut = controller(store, center)
        let addStarted = ReminderGate(), releaseAdd = ReminderGate(), drainStarted = ReminderGate()
        center.pauseAdd = { addStarted.open(); await releaseAdd.wait() }
        sut.setEnabled(true)
        await addStarted.wait()
        #expect(sut.hasPendingWork)
        var drained = false
        let drain = Task {
            drainStarted.open()
            await sut.prepareToQuit()
            drained = true
        }
        await drainStarted.wait()
        #expect(!drained)
        releaseAdd.open()
        await drain.value
        #expect(drained && !sut.hasPendingWork && center.requests.count == 1)
        sut.setEnabled(false)
        await sut.prepareToQuit()
        #expect(!sut.hasPendingWork && center.requests.isEmpty)
    }

    @Test func quittingDoesNotWaitForOrStartAPermissionPrompt() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        center.status = .notDetermined
        let sut = controller(store, center)
        let asking = ReminderGate(), answer = ReminderGate()
        center.pauseAuthorization = { asking.open(); await answer.wait() }
        sut.setEnabled(true)
        await asking.wait()
        #expect(!sut.hasPendingWork)
        await sut.prepareToQuit()
        answer.open()
        await sut.settle()
        #expect(center.requests.count == 1)
        sut.setEnabled(false); await sut.prepareToQuit()

        let fresh = ReminderCenter()
        fresh.status = .notDetermined
        let other = controller(store, fresh)
        other.setEnabled(true)
        await other.prepareToQuit()
        #expect(fresh.permissionRequests == 0 && fresh.requests.isEmpty)
        // A cancelled quit can refresh and ask normally again.
        other.refresh(); await other.settle()
        #expect(fresh.permissionRequests == 1 && fresh.requests.count == 1)
        other.setEnabled(false); await other.prepareToQuit()
    }

    @Test func capRefillsAfterAnItemLeavesThePlan() async throws {
        let center = ReminderCenter()
        var records = try pages(timed: false)
        let template = records[item]!
        for n in 0..<65 {
            var record = template
            record.title = "Task \(n)"
            records[PageID()] = record
        }
        let store = InMemorySpacePageStore(pages: records)
        let sut = controller(store, center)
        sut.setEnabled(true); await sut.settle()
        #expect(center.requests.count == 50)
        let old = try #require(center.requests.values.first)
        let removed = try PageID(try #require(old.content.userInfo["pageID"] as? String))
        store.remove(removed); await sut.settle()
        #expect(center.requests.count == 50 && center.requests[old.identifier] == nil)
        sut.setEnabled(false); await sut.settle()
    }

    @Test func denialDoesNotScheduleAndUnrelatedOrDisabledActionsDoNotEdit() async throws {
        let center = ReminderCenter(), store = InMemorySpacePageStore(pages: try pages())
        center.status = .denied
        let sut = controller(store, center)
        sut.setEnabled(true); await sut.settle()
        #expect(center.requests.isEmpty && center.permissionRequests == 0)
        center.status = .authorized; sut.refresh(); await sut.settle()
        let request = try #require(center.requests.values.first)
        let thread = UNNotificationRequest(identifier: "thread.notice", content: request.content, trigger: nil)
        await sut.respond(to: thread, action: SpaceReminderNotification.doneAction)
        #expect(store.pages[item]?.props[FieldID.done] == .checkbox(false))
        sut.setEnabled(false); await sut.settle()
        await sut.respond(to: request, action: SpaceReminderNotification.doneAction)
        #expect(store.pages[item]?.props[FieldID.done] == .checkbox(false))
    }
}
