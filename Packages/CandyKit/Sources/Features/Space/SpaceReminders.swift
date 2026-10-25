import AppKit
import CryptoKit
import SpaceEngine
import SpaceModel
import SpacePlanning
import UserNotifications

/// The only notification-center calls Space makes. Tests substitute an in-memory center.
@MainActor
public protocol SpaceNotificationCenter: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func registerCategory(_ category: UNNotificationCategory) async
    func pending() async -> [UNNotificationRequest]
    func delivered() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func withdraw(_ identifiers: [String])
}

@MainActor
public final class SystemSpaceNotificationCenter: SpaceNotificationCenter {
    private let center: UNUserNotificationCenter
    public init(center: UNUserNotificationCenter = .current()) { self.center = center }
    public func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    public func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    public func registerCategory(_ category: UNNotificationCategory) async {
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != category.identifier }
        categories.insert(category)
        center.setNotificationCategories(categories)
    }
    public func pending() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    public func delivered() async -> [UNNotificationRequest] { await center.deliveredNotifications().map(\.request) }
    public func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    public func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

public enum SpaceReminderNotification {
    public static let categoryID = "space.reminder"
    public static let doneAction = "space.markDone"
    public static let snoozeAction = "space.snooze"
    public static func owns(_ id: String) -> Bool { id.hasPrefix("space.") }
    public static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [
            UNNotificationAction(identifier: doneAction, title: "Mark done"),
            UNNotificationAction(identifier: snoozeAction, title: "Snooze 10 min")
        ], intentIdentifiers: [], options: [])
    }

    public static func request(_ reminder: PlannedReminder, stamp: String, locale: Locale = .current) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title.isEmpty ? "Untitled" : reminder.title
        let point = reminder.itemTimeInDeviceZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = (try? point.resolved(in: formatter.timeZone, dateOnlyHour: 9)).map { formatter.string(from: $0) } ?? point.rawValue
        content.body = [reminder.parentTitle, time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        content.categoryIdentifier = categoryID
        content.sound = .default
        content.userInfo = ["pageID": reminder.pageID.rawValue, "stamp": stamp, "fieldID": reminder.fieldID]
        return UNNotificationRequest(identifier: reminder.id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: reminder.components, repeats: false))
    }

    /// Only a digest goes in userInfo, never the rest of the encrypted page's contents.
    static func stamp(_ page: PageRecord, parentTitle: String?) throws -> String {
        var data = try SpaceJSON.encode(page)
        data.append(try SpaceJSON.encode(parentTitle))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Copies the immutable response data across the delegate's isolation boundary. Apple's
/// UNNotificationRequest and its userInfo dictionary are not Sendable in the macOS SDK.
public struct SpaceReminderResponse: Sendable {
    public let identifier: String
    public let action: String
    private let title: String
    private let body: String
    private let page: String
    private let field: String
    private let stamp: String

    public init?(request: UNNotificationRequest, action: String) {
        guard SpaceReminderNotification.owns(request.identifier),
              let page = request.content.userInfo["pageID"] as? String,
              let field = request.content.userInfo["fieldID"] as? String,
              let stamp = request.content.userInfo["stamp"] as? String else { return nil }
        identifier = request.identifier
        self.action = action
        title = request.content.title
        body = request.content.body
        self.page = page
        self.field = field
        self.stamp = stamp
    }

    func request() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = SpaceReminderNotification.categoryID
        content.sound = .default
        content.userInfo = ["pageID": page, "fieldID": field, "stamp": stamp]
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

/// Reconciles a complete planner output with this device's OS-owned requests. A single worker
/// serializes async center calls; edits during permission or scheduling cause another pass.
/// A one-shot wake at the next fire refills the plan. There is no idle polling.
@MainActor
public final class SpaceReminderController {
    private let store: SpacePageStore
    private let center: SpaceNotificationCenter
    private let clock: () -> Date
    private let zone: () -> TimeZone
    private let automaticWakes: Bool
    private var enabled = false
    private var requestingPermission = false
    private var drainingForQuit = false
    private var revision = 0
    private var worker: Task<Void, Never>?
    private var observer: Int?
    private var systemObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    public var openPage: (PageID) -> Void = { _ in }
    /// The app supplies its encrypted writer's flush, so a background action finishes durably.
    public var flush: () async throws -> Void = {}
    public var onFailure: (Error) -> Void = { _ in }

    public init(store: SpacePageStore, center: SpaceNotificationCenter = SystemSpaceNotificationCenter(),
                clock: @escaping () -> Date = Date.init, zone: @escaping () -> TimeZone = { .current },
                automaticWakes: Bool = true) {
        self.store = store
        self.center = center
        self.clock = clock
        self.zone = zone
        self.automaticWakes = automaticWakes
    }

    /// Call only after the local copy has loaded. Disable also works on the cold launch path,
    /// without opening Space's key or files, and clears old requests from previous launches.
    public func setEnabled(_ value: Bool) {
        if value != enabled {
            enabled = value
            if value {
                observer = store.observe { [weak self] in self?.refresh() }
                if automaticWakes {
                    for name in [NSNotification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
                                 NSApplication.didBecomeActiveNotification, NSWorkspace.didWakeNotification] {
                        let source = name == NSWorkspace.didWakeNotification ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
                        systemObservers.append(source.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.refresh() }
                        })
                    }
                }
            } else {
                if let observer { store.removeObserver(observer) }; observer = nil
                for token in systemObservers {
                    NotificationCenter.default.removeObserver(token)
                    NSWorkspace.shared.notificationCenter.removeObserver(token)
                }
                systemObservers.removeAll()
                timer?.invalidate(); timer = nil
            }
        }
        refresh()
    }

    public func refresh() {
        revision += 1
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while true {
                let version = revision
                do { try await reconcile(version: version) }
                catch { onFailure(error) }
                if version == revision { break }
            }
            worker = nil
        }
    }

    /// Waits for all queued center work, including changes made while an async call was suspended.
    public func settle() async { while let worker { await worker.value } }

    /// Scheduling and withdrawal must reach the system before the app exits. An unanswered
    /// permission prompt must not trap quitting, and a quit must not start a new prompt.
    public var hasPendingWork: Bool { worker != nil && !requestingPermission }

    public func prepareToQuit() async {
        guard !requestingPermission else { return }
        drainingForQuit = true
        defer { drainingForQuit = false }
        await settle()
    }

    private func reconcile(version: Int) async throws {
        let pending = await center.pending().filter { SpaceReminderNotification.owns($0.identifier) }
        let delivered = await center.delivered().filter { SpaceReminderNotification.owns($0.identifier) }
        guard version == revision else { return }
        guard enabled else {
            center.withdraw(Array(Set((pending + delivered).map(\.identifier))))
            return
        }
        await center.registerCategory(SpaceReminderNotification.category)
        let pages = store.pages, now = clock(), deviceZone = zone()
        let plan = try await Task.detached {
            try ReminderPlanner.plan(pages: pages, now: now, deviceTimeZone: deviceZone)
        }.value
        var status = await center.authorizationStatus()
        guard version == revision else { return }
        if !drainingForQuit, status == .notDetermined, pages.contains(where: { id, page in
            store.isLive(id) && page.props[FieldID.done] != .checkbox(true) && page.props.values.contains {
                if case .date(let value) = $0, let remind = value.remind {
                    if case .unknown = remind { return false }
                    return true
                }
                return false
            }
        }) {
            requestingPermission = true
            defer { requestingPermission = false }
            status = try await center.requestAuthorization() ? .authorized : .denied
        }
        guard version == revision else { return }
        let allowed = status == .authorized || status == .provisional
        var desired: [UNNotificationRequest] = []
        if allowed {
            desired = try plan.map { reminder in
                let page = pages[reminder.pageID]!
                return SpaceReminderNotification.request(reminder, stamp: try SpaceReminderNotification.stamp(page, parentTitle: reminder.parentTitle))
            }
            // Snoozes live only in this device's center and survive relaunch. An item edit invalidates them.
            desired += pending.filter { $0.identifier.hasSuffix(".snooze") && valid($0) }
            desired.sort { nextDate($0) < nextDate($1) }
            desired = Array(desired.prefix(ReminderPlanner.requestLimit))
        }
        let ids = Set(desired.map(\.identifier))
        let withdrawn = Set(pending.filter { !ids.contains($0.identifier) }.map(\.identifier)
                            + delivered.filter { !valid($0) }.map(\.identifier))
        center.withdraw(Array(withdrawn))
        for request in desired {
            guard version == revision else { return }
            // Withdrawing an old delivered version also removes a pending version with the same id.
            if withdrawn.contains(request.identifier) || pending.first(where: { $0.identifier == request.identifier }) != request {
                try await center.add(request)
            }
        }
        guard version == revision else { return }
        timer?.invalidate(); timer = nil
        if automaticWakes, let next = desired.map({ nextDate($0) }).filter({ $0 != .distantFuture }).min() {
            timer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSince(clock()) + 1), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func nextDate(_ request: UNNotificationRequest) -> Date {
        if let trigger = request.trigger as? UNCalendarNotificationTrigger { return trigger.nextTriggerDate() ?? .distantFuture }
        if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger { return trigger.nextTriggerDate() ?? .distantFuture }
        return .distantFuture
    }

    private func valid(_ request: UNNotificationRequest) -> Bool {
        guard let raw = request.content.userInfo["pageID"] as? String, let id = try? PageID(raw),
              let page = store.pages[id], store.isLive(id), page.props[FieldID.done] != .checkbox(true),
              let field = request.content.userInfo["fieldID"] as? String,
              case .date(let value) = page.props[field], value.remind != nil,
              let stamp = try? SpaceReminderNotification.stamp(page, parentTitle: page.parent.flatMap { store.pages[$0]?.title }) else { return false }
        return request.content.userInfo["stamp"] as? String == stamp
    }

    /// Called by the shared delegate for both a cold-launch response and a foreground banner.
    public func respond(to request: UNNotificationRequest, action: String) async {
        guard let response = SpaceReminderResponse(request: request, action: action) else { return }
        await respond(to: response)
    }

    public func respond(to response: SpaceReminderResponse) async {
        let request = response.request(), action = response.action
        guard enabled, valid(request), let raw = request.content.userInfo["pageID"] as? String,
              let id = try? PageID(raw) else { refresh(); await settle(); return }
        do {
            switch action {
            case UNNotificationDefaultActionIdentifier:
                openPage(id)
            case SpaceReminderNotification.doneAction:
                if let document = store as? SpaceDocumentStore {
                    document.edit([RecordChange(kind: .page, id: id, set: ["props.done": .bool(true)])])
                } else if var page = store.pages[id] {
                    page.props[FieldID.done] = .checkbox(true)
                    store.put([id: page])
                }
                try await flush()
            case SpaceReminderNotification.snoozeAction:
                let base = request.identifier.hasSuffix(".snooze") ? String(request.identifier.dropLast(7)) : request.identifier
                let snooze = UNNotificationRequest(identifier: base + ".snooze", content: request.content,
                                                   trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
                center.withdraw([request.identifier])
                try await center.add(snooze)
            default: break
            }
            if action != SpaceReminderNotification.snoozeAction { center.withdraw([request.identifier]) }
        } catch { onFailure(error) }
        refresh()
        await settle()
    }
}
