import Foundation
import T3Protocol

/// One thread's drawer as T3 keeps it (`ThreadTerminalUiState`, apps/web/src/terminalUiStateStore.ts):
/// whether it is open, its height, its terminals and their split groups. Persisted per thread.
public struct TerminalDrawerState: Codable, Sendable, Equatable {
    /// `DEFAULT_THREAD_TERMINAL_HEIGHT` (web types.ts:34).
    public static let defaultHeight: CGFloat = 280
    /// `MIN_DRAWER_HEIGHT` and `MAX_DRAWER_HEIGHT_RATIO` (ThreadTerminalDrawer.tsx:99-100).
    public static let minHeight: CGFloat = 180
    public static let maxHeightRatio: CGFloat = 0.75
    /// `MAX_TERMINALS_PER_GROUP` (web types.ts:36).
    public static let maxPerGroup = 4

    public var open = false
    public var height: CGFloat = defaultHeight
    public var terminalIds: [String] = []
    public var activeTerminalId: String = ""
    public var terminalGroups: [TerminalGroup] = []
    public var activeTerminalGroupId: String = ""

    public init(open: Bool = false, height: CGFloat = defaultHeight, terminalIds: [String] = [], activeTerminalId: String = "",
                terminalGroups: [TerminalGroup] = [], activeTerminalGroupId: String = "") {
        self.open = open; self.height = height; self.terminalIds = terminalIds; self.activeTerminalId = activeTerminalId
        self.terminalGroups = terminalGroups; self.activeTerminalGroupId = activeTerminalGroupId
    }

    private enum CodingKeys: String, CodingKey { case open, height, terminalIds, activeTerminalId, terminalGroups, activeTerminalGroupId }

    /// States saved before groups existed decode with none; `normalized` then gives each terminal its own.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? Self.defaultHeight
        terminalIds = try c.decodeIfPresent([String].self, forKey: .terminalIds) ?? []
        activeTerminalId = try c.decodeIfPresent(String.self, forKey: .activeTerminalId) ?? ""
        terminalGroups = try c.decodeIfPresent([TerminalGroup].self, forKey: .terminalGroups) ?? []
        activeTerminalGroupId = try c.decodeIfPresent(String.self, forKey: .activeTerminalGroupId) ?? ""
        self = normalized
    }

    /// `clampDrawerHeight` (ThreadTerminalDrawer.tsx:122-125): rounded, at least 180, at most `maxHeight`,
    /// which wins when it is under 180.
    public static func clampHeight(_ height: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let safe = height.isFinite ? height : defaultHeight
        return min(max(safe.rounded(), minHeight), maxHeight)
    }

    /// `resolveTerminalDrawerMaxHeight` (ThreadTerminalDrawer.tsx:108-120, 055a8418c1): 75% of the window but
    /// never under 180, and no more than the chat column leaves under its header and above the composer,
    /// which overlays the timeline. That second cap may be under 180, so a short window shrinks the drawer
    /// instead of pushing the composer into the header.
    public static func maxHeight(windowHeight: CGFloat, columnHeight: CGFloat, headerHeight: CGFloat, composerHeight: CGFloat) -> CGFloat {
        let windowCap = max(minHeight, (windowHeight * maxHeightRatio).rounded(.down))
        return min(windowCap, max(0, columnHeight - headerHeight - composerHeight))
    }

    /// `findReusableProjectScriptTerminal` (apps/web/src/lib/projectScriptTerminal.ts): an idle drawer
    /// terminal, the active one first. Right-panel terminals never count, even when listed as drawer ones,
    /// because one PTY would show in both places and closing the drawer copy would kill the panel's shell.
    public static func reusableScriptTerminal(drawerIds: [String], activeId: String, panelIds: Set<String>, runningIds: Set<String>) -> String? {
        let idle = unique(drawerIds).filter { !panelIds.contains($0) && !runningIds.contains($0) }
        return idle.contains(activeId) ? activeId : idle.first
    }

    /// The terminal the drawer shows: the active one if it still exists, else the first.
    public var resolvedActiveId: String? {
        terminalIds.contains(activeTerminalId) ? activeTerminalId : terminalIds.first
    }

    // MARK: Transitions (terminalUiStateStore.ts)

    /// `normalizeThreadTerminalUiState`: trimmed unique ids, a valid active terminal, every terminal
    /// in exactly one group, and an active group that exists.
    public var normalized: TerminalDrawerState {
        let ids = Self.unique(terminalIds)
        let active = ids.contains(activeTerminalId) ? activeTerminalId : (ids.first ?? "")
        let groups = Self.normalizeGroups(terminalGroups, ids)
        let groupId = groups.contains(where: { $0.id == activeTerminalGroupId }) ? activeTerminalGroupId
            : groups.first(where: { $0.terminalIds.contains(active) })?.id ?? groups.first?.id ?? ""
        return TerminalDrawerState(open: open, height: height.isFinite && height > 0 ? height : Self.defaultHeight,
                                   terminalIds: ids, activeTerminalId: active, terminalGroups: groups, activeTerminalGroupId: groupId)
    }

    /// `newThreadTerminal`: the terminal gets its own group and becomes active; the drawer opens.
    public mutating func newTerminal(_ terminalId: String) { upsert(terminalId, split: false, direction: .horizontal) }

    /// The drawer's old name for `newTerminal`.
    public mutating func ensure(_ terminalId: String) { newTerminal(terminalId) }

    /// `splitThreadTerminal`: the terminal joins the active group right after the active terminal,
    /// and the group takes `direction`. A full group (4) refuses a new terminal.
    public mutating func split(_ terminalId: String, direction: TerminalGroup.Direction) {
        upsert(terminalId, split: true, direction: direction)
    }

    /// `upsertTerminalIntoGroups`.
    private mutating func upsert(_ terminalId: String, split: Bool, direction: TerminalGroup.Direction) {
        let current = normalized
        let id = terminalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { self = current; return }
        let splitting = split && !current.terminalIds.isEmpty
        let isNew = !current.terminalIds.contains(id)
        var next = current
        if isNew { next.terminalIds.append(id) }
        var groups = current.terminalGroups
        if let index = groups.firstIndex(where: { $0.terminalIds.contains(id) }) {
            groups[index].terminalIds.removeAll { $0 == id }
            if groups[index].terminalIds.isEmpty { groups.remove(at: index) }
        }
        if !splitting {
            var used = Set(groups.map(\.id))
            let groupId = Self.uniqueGroupId("group-" + id, &used)
            groups.append(TerminalGroup(id: groupId, terminalIds: [id]))
            next.open = true
            next.activeTerminalId = id
            next.terminalGroups = groups
            next.activeTerminalGroupId = groupId
            self = next.normalized
            return
        }
        var destination = groups.firstIndex { $0.id == current.activeTerminalGroupId }
            ?? groups.firstIndex { $0.terminalIds.contains(current.activeTerminalId) }
        if destination == nil {
            var used = Set(groups.map(\.id))
            groups.append(TerminalGroup(id: Self.uniqueGroupId("group-" + current.activeTerminalId, &used), terminalIds: [current.activeTerminalId]))
            destination = groups.count - 1
        }
        guard let d = destination else { self = current; return }
        if isNew, !groups[d].terminalIds.contains(id), groups[d].terminalIds.count >= Self.maxPerGroup { self = current; return }
        if !groups[d].terminalIds.contains(id) {
            if let anchor = groups[d].terminalIds.firstIndex(of: current.activeTerminalId) {
                groups[d].terminalIds.insert(id, at: anchor + 1)
            } else {
                groups[d].terminalIds.append(id)
            }
        }
        groups[d].splitDirection = direction
        next.open = true
        next.activeTerminalId = id
        next.terminalGroups = groups
        next.activeTerminalGroupId = groups[d].id
        self = next.normalized
    }

    /// `setThreadActiveTerminal`: the terminal and its group become active.
    public mutating func activate(_ terminalId: String) {
        var next = normalized
        guard next.terminalIds.contains(terminalId) else { self = next; return }
        next.activeTerminalId = terminalId
        next.activeTerminalGroupId = next.terminalGroups.first { $0.terminalIds.contains(terminalId) }?.id ?? next.activeTerminalGroupId
        self = next
    }

    /// `closeThreadTerminal`: the last terminal resets the drawer to its default (closed, default
    /// height); otherwise the neighbor at the closed one's index becomes active.
    public mutating func close(_ terminalId: String) {
        let current = normalized
        guard let index = current.terminalIds.firstIndex(of: terminalId) else { self = current; return }
        let remaining = current.terminalIds.filter { $0 != terminalId }
        if remaining.isEmpty { self = TerminalDrawerState(); return }
        let active = current.activeTerminalId == terminalId ? remaining[min(index, remaining.count - 1)] : current.activeTerminalId
        let groups = current.terminalGroups.compactMap { group -> TerminalGroup? in
            var g = group
            g.terminalIds.removeAll { $0 == terminalId }
            return g.terminalIds.isEmpty ? nil : g
        }
        let groupId = groups.first { $0.terminalIds.contains(active) }?.id ?? groups.first?.id ?? "group-" + active
        self = TerminalDrawerState(open: current.open, height: current.height, terminalIds: remaining, activeTerminalId: active,
                                   terminalGroups: groups, activeTerminalGroupId: groupId).normalized
    }

    /// `reconcileThreadTerminalSessionIds`: the server's terminals for the thread replace the list.
    public mutating func reconcile(_ ids: [String]) {
        let current = normalized
        guard current.terminalIds != ids else { self = current; return }
        let active = ids.contains(current.activeTerminalId) ? current.activeTerminalId : (ids.first ?? "")
        let groups = Self.normalizeGroups(current.terminalGroups, ids)
        var next = current
        next.terminalIds = ids
        next.activeTerminalId = active
        next.terminalGroups = groups
        next.activeTerminalGroupId = groups.first { $0.terminalIds.contains(active) }?.id ?? groups.first?.id ?? ""
        self = next.normalized
    }

    // MARK: What the drawer draws (ThreadTerminalDrawer.tsx:1237-1332)

    /// The groups in the order of their first terminal (`resolvedTerminalGroups`).
    public var resolvedGroups: [TerminalGroup] {
        let ids = Self.unique(terminalIds)
        let order = Dictionary(ids.enumerated().map { ($1, $0) }) { a, _ in a }
        return Self.normalizeGroups(terminalGroups, ids).enumerated().sorted { a, b in
            let ra = a.element.terminalIds.compactMap { order[$0] }.min() ?? .max
            let rb = b.element.terminalIds.compactMap { order[$0] }.min() ?? .max
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    private var activeGroupIndex: Int {
        let groups = resolvedGroups
        let active = resolvedActiveId ?? ""
        return groups.firstIndex { $0.id == activeTerminalGroupId } ?? groups.firstIndex { $0.terminalIds.contains(active) } ?? 0
    }

    /// The active group's terminals, shown side by side or stacked.
    public var visibleTerminalIds: [String] {
        let groups = resolvedGroups, index = activeGroupIndex
        if index < groups.count { return groups[index].terminalIds }
        return resolvedActiveId.map { [$0] } ?? []
    }

    public var visibleSplitDirection: TerminalGroup.Direction {
        let groups = resolvedGroups, index = activeGroupIndex
        return index < groups.count ? groups[index].splitDirection : .horizontal
    }

    /// `hasTerminalSidebar`: more than one terminal shows the list aside.
    public var hasTerminalList: Bool { Self.unique(terminalIds).count > 1 }
    /// `showGroupHeaders`.
    public var showGroupHeaders: Bool {
        let groups = resolvedGroups
        return groups.count > 1 || groups.contains { $0.terminalIds.count > 1 }
    }
    /// `hasReachedSplitLimit`.
    public var hasReachedSplitLimit: Bool { visibleTerminalIds.count >= Self.maxPerGroup }

    // MARK: Helpers

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static func uniqueGroupId(_ base: String, _ used: inout Set<String>) -> String {
        var candidate = base, n = 2
        while used.contains(candidate) { candidate = "\(base)-\(n)"; n += 1 }
        used.insert(candidate)
        return candidate
    }

    /// `normalizeTerminalGroups`: known terminals only, each in its first group; the rest get their own.
    static func normalizeGroups(_ groups: [TerminalGroup], _ ids: [String]) -> [TerminalGroup] {
        guard !ids.isEmpty else { return [] }
        let valid = Set(ids)
        var assigned = Set<String>(), used = Set<String>()
        var out: [TerminalGroup] = []
        for group in groups {
            let members = unique(group.terminalIds).filter { valid.contains($0) && !assigned.contains($0) }
            guard !members.isEmpty else { continue }
            assigned.formUnion(members)
            let trimmed = group.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "group-" + members[0] : trimmed
            out.append(TerminalGroup(id: uniqueGroupId(base, &used), terminalIds: members, splitDirection: group.splitDirection))
        }
        for id in ids where !assigned.contains(id) {
            out.append(TerminalGroup(id: uniqueGroupId("group-" + id, &used), terminalIds: [id]))
        }
        return out
    }
}

/// `ThreadTerminalGroup` (web types.ts:39-43): terminals shown together, side by side (horizontal,
/// the default) or stacked (vertical).
public struct TerminalGroup: Codable, Sendable, Equatable {
    public enum Direction: String, Codable, Sendable { case horizontal, vertical }
    public var id: String
    public var terminalIds: [String]
    public var splitDirection: Direction

    public init(id: String, terminalIds: [String], splitDirection: Direction = .horizontal) {
        self.id = id; self.terminalIds = terminalIds; self.splitDirection = splitDirection
    }

    private enum CodingKeys: String, CodingKey { case id, terminalIds, splitDirection }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        terminalIds = try c.decodeIfPresent([String].self, forKey: .terminalIds) ?? []
        splitDirection = (try? c.decodeIfPresent(Direction.self, forKey: .splitDirection)) ?? .horizontal
    }
}

/// Which threads have a terminal with a running subprocess, from `subscribeTerminalMetadata`
/// (`selectRunningSubprocessTerminalIds`). Feeds the sidebar's terminal indicator.
public struct TerminalActivity: Sendable, Equatable {
    public private(set) var terminals: [String: TerminalSummary] = [:]

    public init() {}

    private static func key(_ threadId: String, _ terminalId: String) -> String { threadId + "\u{0}" + terminalId }

    /// Applies one metadata event; returns whether the running set changed.
    @discardableResult
    public mutating func apply(_ event: TerminalMetadataEvent) -> Bool {
        let before = runningThreads
        switch event {
        case .snapshot(let list):
            terminals = Dictionary(list.map { (Self.key($0.threadId, $0.terminalId), $0) }) { $1 }
        case .upsert(let summary):
            terminals[Self.key(summary.threadId, summary.terminalId)] = summary
        case .remove(let threadId, let terminalId):
            terminals[Self.key(threadId, terminalId)] = nil
        }
        return runningThreads != before
    }

    /// Local thread id to its count of terminals running a subprocess.
    public var runningThreads: [String: Int] {
        var counts: [String: Int] = [:]
        for summary in terminals.values where summary.hasRunningSubprocess { counts[summary.threadId, default: 0] += 1 }
        return counts
    }

    public func summary(threadId: String, terminalId: String) -> TerminalSummary? {
        terminals[Self.key(threadId, terminalId)]
    }

    /// A thread's terminals running a subprocess (`useThreadRunningTerminalIds`).
    public func runningTerminalIds(threadId: String) -> Set<String> {
        Set(terminals.values.filter { $0.threadId == threadId && $0.hasRunningSubprocess }.map(\.terminalId))
    }

    /// A thread's terminals the server knows, in T3's numeric id order.
    public func terminalIds(threadId: String) -> [String] {
        terminals.values.filter { $0.threadId == threadId }.map(\.terminalId)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// What the renderer does with one attach event.
public enum TerminalRenderAction: Sendable, Equatable {
    /// Clear the screen and scrollback, then write (a snapshot's history, a restart, a clear).
    case reset(String)
    case write(String)
    /// `writeSystemMessage`: "\r\n[terminal] message\r\n".
    case message(String)
}

/// The attach stream's state machine (client-runtime terminalSession.ts `applyTerminalAttachStreamEvent`
/// plus the drawer's exit handling in ThreadTerminalDrawer.tsx `synchronizeTerminalStatus`).
public struct TerminalSessionModel: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case closed, starting, running, exited, error }

    public private(set) var status: Status = .closed
    public private(set) var label = ""
    public private(set) var hasRunningSubprocess = false
    /// Events applied since the attach began (`version`); 0 before the first snapshot.
    public private(set) var version = 0
    private var exitHandled = false

    public init() {}

    /// The server accepts `terminal.resize` only for a running session the client has seen.
    public var canResize: Bool { version > 0 && status == .running }

    public struct Outcome: Sendable, Equatable {
        public var actions: [TerminalRenderAction] = []
        /// The process ended or the server closed the session: the drawer closes the terminal.
        public var sessionEnded = false
        /// The session (re)started: resend the grid size.
        public var resendSize = false
    }

    public mutating func apply(_ event: TerminalAttachEvent) -> Outcome {
        var out = Outcome()
        switch event {
        case .snapshot(let snapshot), .restarted(let snapshot):
            status = Status(snapshot.status)
            label = snapshot.label
            out.actions.append(.reset(snapshot.history))
            out.resendSize = status == .running
        case .output(let data):
            if status == .closed { status = .running; out.resendSize = true }
            out.actions.append(.write(data))
        case .cleared:
            out.actions.append(.reset(""))
        case .exited:
            status = .exited
        case .closed:
            status = .closed
        case .error(let message):
            status = .error
            out.actions.append(.message(message))
        case .activity(let running, let newLabel):
            hasRunningSubprocess = running
            label = newLabel
            return out
        case .unknown:
            return out
        }
        version += 1
        // `shouldHandleTerminalExit`: once per exit, and a running session re-arms it.
        if status == .running {
            exitHandled = false
        } else if (status == .exited || status == .closed) && !exitHandled {
            exitHandled = true
            out.actions.append(.message(status == .closed ? "Terminal closed" : "Process exited"))
            out.sessionEnded = true
        }
        return out
    }

    /// The renderer's bytes for a system message.
    public static func messageText(_ message: String) -> String { "\r\n[terminal] \(message)\r\n" }
}

extension TerminalSessionModel.Status {
    init(_ status: TerminalSessionStatus) {
        switch status {
        case .starting: self = .starting
        case .running: self = .running
        case .exited: self = .exited
        case .error: self = .error
        }
    }
}
