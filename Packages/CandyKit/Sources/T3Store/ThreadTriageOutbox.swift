import Foundation
import T3Protocol

/// Settle and snooze taken while an environment is not connected (#24917, client-runtime
/// state/threadTriageOutbox.ts and platform/threadTriageOutboxStore.ts at 5258). The change is
/// stored on the device, shown at once, and sent under its own command id when the environment's
/// shell is live again. If the thread changed there meanwhile, the server's state wins and the
/// change is dropped.
public struct ThreadTriageOutbox: Sendable, Equatable {
    public enum Action: Codable, Sendable, Equatable {
        case settle
        case snooze(until: String)

        public var type: String {
            switch self {
            case .settle: "settle"
            case .snooze: "snooze"
            }
        }
        public var update: OptimisticThreadUpdate {
            switch self {
            case .settle: .settle
            case .snooze(let until): .snooze(until: T3Timestamp(until))
            }
        }
    }

    /// `PendingThreadTriage` (threadTriageOutboxStore.ts:8-19).
    public struct Entry: Codable, Sendable, Equatable {
        public var environmentId: String
        /// The server's thread id, unscoped.
        public var threadId: String
        public var commandId: String
        public var action: Action
        public var queuedAt: T3Timestamp
        /// The thread as the user saw it (`seenState`); if it shows otherwise on reconnect, the change is dropped.
        public var seen: String
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    /// What the user acted on: the thread's work and every triage decision with its time. A rename, tag
    /// change or visit is left out, so it does not drop the queued change (threadTriageOutbox.ts:39-58).
    public static func seenState(_ thread: ThreadShell) -> String {
        func ms(_ t: T3Timestamp?) -> String { t?.epochMs.map(String.init) ?? "null" }
        return [thread.latestRunId?.rawValue ?? "null", thread.status.rawValue, String(thread.itemCount),
                thread.pendingRuntimeRequest?.id.rawValue ?? "null", thread.settledOverride?.rawValue ?? "null",
                ms(thread.settledAt), ms(thread.unsettledAt), ms(thread.snoozedUntil), ms(thread.snoozedAt), ms(thread.pinnedAt)]
            .joined(separator: "|")
    }

    /// The change would do something to the thread as it stands, the way the optimistic update judges it.
    public static func applies(_ action: Action, to thread: ThreadShell, at now: T3Timestamp) -> Bool {
        action.update.apply(thread, now: now, accepted: false) != thread
    }

    public func pending(environmentId: String) -> [Entry] { entries.filter { $0.environmentId == environmentId } }

    /// The threads that read "Pending" in the sidebar (`pendingSyncAtom`).
    public func pendingThreads(environmentId: String) -> Set<String> { Set(pending(environmentId: environmentId).map(\.threadId)) }

    /// Stores the change. One per thread, and a snooze cannot replace a settle, which online it keeps
    /// (threadTriageOutbox.ts:200-228). False when nothing was stored.
    @discardableResult
    public mutating func queue(_ action: Action, thread: ThreadShell, environmentId: String,
                               commandId: String = UUID().uuidString.lowercased(), now: T3Timestamp = T3Timestamp(Date())) -> Bool {
        guard Self.applies(action, to: thread, at: now) else { return false }
        let same = { (e: Entry) in e.environmentId == environmentId && e.threadId == thread.id.rawValue }
        if case .snooze = action, entries.first(where: same)?.action == .settle { return false }
        entries.removeAll(where: same)
        entries.append(Entry(environmentId: environmentId, threadId: thread.id.rawValue, commandId: commandId,
                             action: action, queuedAt: now, seen: Self.seenState(thread)))
        return true
    }

    /// Undo, Un-settle or Wake of a queued change removes it (`cancelQueued`, threadTriageOutbox.ts:248-298).
    /// True when one was removed.
    @discardableResult
    public mutating func cancel(environmentId: String, threadId: String, type: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.environmentId == environmentId && $0.threadId == threadId && $0.action.type == type }
        return entries.count != before
    }

    /// The server now has a newer decision for the thread, or the change went out.
    public mutating func forget(environmentId: String, threadId: String) {
        entries.removeAll { $0.environmentId == environmentId && $0.threadId == threadId }
    }

    public mutating func forget(commandId: String) { entries.removeAll { $0.commandId == commandId } }

    /// Removing the environment drops its changes (`clearEnvironment`).
    public mutating func remove(environmentId: String) { entries.removeAll { $0.environmentId == environmentId } }

    /// The live shell with each queued change applied as of when it was made (`snapshotAtom`, :160-174).
    public func apply(_ snapshot: ShellSnapshot, environmentId: String) -> ShellSnapshot {
        let byThread = Dictionary(pending(environmentId: environmentId).map { ($0.threadId, $0) }, uniquingKeysWith: { $1 })
        guard !byThread.isEmpty else { return snapshot }
        var out = snapshot
        out.threads = snapshot.threads.map { thread in
            byThread[thread.id.rawValue].map { $0.action.update.apply(thread, now: $0.queuedAt, accepted: false) } ?? thread
        }
        return out
    }

    /// The drain for a live shell (`replay`, :128-150): a change goes out when its thread still shows as the
    /// user saw it and the change still applies; every other one is dropped, since the live shell wins.
    public func replay(_ snapshot: ShellSnapshot, environmentId: String, now: T3Timestamp = T3Timestamp(Date()))
        -> (send: [Entry], drop: [Entry]) {
        var send: [Entry] = [], drop: [Entry] = []
        for entry in pending(environmentId: environmentId) {
            if let thread = snapshot.threads.first(where: { $0.id.rawValue == entry.threadId }),
               Self.seenState(thread) == entry.seen, Self.applies(entry.action, to: thread, at: now) {
                send.append(entry)
            } else {
                drop.append(entry)
            }
        }
        return (send, drop)
    }

    // MARK: Storage

    /// Kept in the app's defaults, which are per bundle id, so test builds never share it with the user's app,
    /// and apart from the shell cache, so clearing that keeps unsynced changes.
    public static let defaultsKey = "threadTriageOutbox.v1"

    public static func load(_ defaults: UserDefaults = .standard) -> ThreadTriageOutbox {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return ThreadTriageOutbox() }
        return ThreadTriageOutbox(entries: entries)
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if entries.isEmpty { defaults.removeObject(forKey: Self.defaultsKey); return }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
