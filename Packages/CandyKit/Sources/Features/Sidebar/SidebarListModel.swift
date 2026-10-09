import Foundation
import T3Protocol
import T3Store

/// One row of the thread list, precomputed so the view only copies values into layers.
/// Field meanings follow `SidebarThreadRow` (apps/web/src/components/Sidebar.tsx:1270-2217).
public struct SidebarRowModel: Equatable, Sendable {
    /// `card` for pinned and active threads, `slim` for snoozed and settled (Sidebar.tsx:5258-5265).
    public enum Variant: Sendable { case card, slim }
    /// The row's primary hover action (`variantAction`, Sidebar.tsx:5274-5280).
    public enum Action: Sendable { case settle, unsettle, unsnooze }

    public var id: ThreadId
    public var variant: Variant
    public var action: Action
    public var section: SidebarSection
    public var title: String
    /// `group.displayName` of the thread's logical project.
    public var projectLabel: String?
    /// The project's own title: the monogram and its color derive from it (ProjectFavicon.tsx).
    public var projectTitle: String?
    public var branch: String?
    public var hasWorktree: Bool
    public var status: SidebarThreadStatus
    public var topStatus: SidebarTopStatus?
    /// `thread.goal?.status === "active"` relabels Working as "Goal".
    public var isGoal: Bool
    public var isUnread: Bool
    public var isWoke: Bool
    public var isPinned: Bool
    public var recedes: Bool
    public var isActive: Bool
    public var isRegeneratingTitle: Bool
    /// Relative time, or the settled time on the settled shelf.
    public var timeLabel: String
    /// Snoozed rows show when they come back (`snoozeWakeLabel`).
    public var snoozeLabel: String?
    /// Start of the work a Working row counts from.
    public var workingStartedMs: Int64?
    public var providerIcon: String
    /// Timestamps behind the labels, for the refresh timer.
    var timeAnchorMs: Int64?
    var snoozeWakeMs: Int64?

    /// The status slot text as T3 renders it, for tests and accessibility.
    public var statusLabel: String? {
        switch topStatus {
        case .working: isGoal ? "Goal" : "Working"
        case .waiting: "Waiting"
        case .approval: "Approval"
        case .input: "Input"
        case .limited: "Limited"
        case .failed: "Failed"
        case .woke: "Woke"
        case .done: "Done"
        case nil: nil
        }
    }
}

public enum SidebarShelf: String, Sendable { case snoozed, settled }

public enum SidebarItem: Equatable, Sendable {
    case row(SidebarRowModel)
    /// "Settled (N)" collapsed, "Settled" expanded (Sidebar.tsx:5457-5499).
    case shelfHeader(SidebarShelf, label: String, expanded: Bool)
    /// "Show N more" under an expanded settled shelf (Sidebar.tsx:5531-5542).
    case showMore(count: Int)

    public var key: String {
        switch self {
        case .row(let r): "thread:\(r.id.rawValue)"
        case .shelfHeader(let shelf, _, _): "shelf:\(shelf.rawValue)"
        case .showMore: "show-more"
        }
    }

    /// Kind for view recycling.
    var kind: Kind {
        switch self {
        case .row(let r): r.variant == .card ? .card : .slim
        case .shelfHeader: .shelf
        case .showMore: .showMore
        }
    }

    enum Kind: CaseIterable { case card, slim, shelf, showMore }

    /// Layout height including the `py-0.5` of a card `li` (Sidebar.tsx:1955-2217). The list adds `gap-px`.
    var height: CGFloat {
        switch kind {
        case .card: 82
        case .slim, .showMore: 36
        case .shelf: 32
        }
    }
}

/// Client-local list state: selection, shelf expansion (T3 keeps it in localStorage, default collapsed)
/// and the settled paging.
public struct SidebarListState: Equatable, Sendable {
    public var activeThreadId: ThreadId?
    public var snoozedExpanded = false
    public var settledExpanded = false
    /// `SETTLED_TAIL_INITIAL_COUNT` then `+ SETTLED_TAIL_PAGE_COUNT` per "Show more".
    public var settledVisibleCount = SidebarListBuilder.settledInitialCount
    public var scopedProjectIds: Set<ProjectId>?
    public var capabilities = SidebarModel.Capabilities(threadSettlement: true, threadSnooze: true)
    /// Visits recorded on this device, for servers without `lastVisitedAt`.
    public var localVisits: [ThreadId: T3Timestamp] = [:]

    public init(activeThreadId: ThreadId? = nil) { self.activeThreadId = activeThreadId }

    public static func == (a: Self, b: Self) -> Bool {
        a.activeThreadId == b.activeThreadId && a.snoozedExpanded == b.snoozedExpanded
            && a.settledExpanded == b.settledExpanded && a.settledVisibleCount == b.settledVisibleCount
            && a.scopedProjectIds == b.scopedProjectIds && a.localVisits == b.localVisits
            && a.capabilities.threadSettlement == b.capabilities.threadSettlement
            && a.capabilities.threadSnooze == b.capabilities.threadSnooze
    }
}

public enum SidebarListBuilder {
    static let settledInitialCount = 10
    static let settledPageCount = 25

    /// `sidebarListItems` (Sidebar.tsx:3781-3829) without the drag-only markers and the beta Working shelf.
    public static func items(snapshot: ShellSnapshot?, state: SidebarListState, nowMs: Int64) -> [SidebarItem] {
        guard let snapshot else { return [] }
        let groups = SidebarModel.buildProjectGroups(snapshot.projects)
        var groupByProject: [ProjectId: SidebarModel.ProjectGroup] = [:]
        for group in groups { for id in group.memberProjectIds { groupByProject[id] = group } }
        var projectById: [ProjectId: ProjectShell] = [:]
        for p in snapshot.projects { projectById[p.id] = p }

        let threads = snapshot.threads.filter { $0.archivedAt == nil && $0.deletedAt == nil }.map(SidebarThread.init)
        let shelves = SidebarModel.buildShelves(threads, scopedProjectIds: state.scopedProjectIds,
                                                capabilities: state.capabilities, nowMs: nowMs)
        func row(_ t: SidebarThread, _ section: SidebarSection) -> SidebarItem {
            .row(rowModel(t, section: section, project: projectById[t.shell.projectId],
                          group: groupByProject[t.shell.projectId], state: state, nowMs: nowMs))
        }
        var items: [SidebarItem] = []
        items += shelves.pinned.map { row($0, .pinned) }
        items += shelves.active.map { row($0, .active) }
        if !shelves.snoozed.isEmpty {
            let expanded = state.snoozedExpanded
            items.append(.shelfHeader(.snoozed, label: expanded ? "Snoozed" : "Snoozed (\(shelves.snoozed.count))", expanded: expanded))
            // A collapsed shelf still renders the open thread (Sidebar.tsx:3027-3032).
            items += shelves.snoozed.filter { expanded || $0.id == state.activeThreadId }.map { row($0, .snoozed) }
        }
        if !items.isEmpty || !shelves.settled.isEmpty {
            let expanded = state.settledExpanded
            items.append(.shelfHeader(.settled, label: expanded ? "Settled" : "Settled (\(shelves.settled.count))", expanded: expanded))
            if expanded {
                var shown = Array(shelves.settled.prefix(state.settledVisibleCount))
                if let active = state.activeThreadId, !shown.contains(where: { $0.id == active }),
                   let hidden = shelves.settled.first(where: { $0.id == active }) {
                    shown.append(hidden) // the open route thread is always appended (Sidebar.tsx:2968-2984)
                }
                items += shown.map { row($0, .settled) }
                let hiddenCount = shelves.settled.count - shown.count
                if hiddenCount > 0 { items.append(.showMore(count: min(hiddenCount, settledPageCount))) }
            } else {
                items += shelves.settled.filter { $0.id == state.activeThreadId }.map { row($0, .settled) }
            }
        }
        return items
    }

    static func rowModel(_ t: SidebarThread, section: SidebarSection, project: ProjectShell?,
                         group: SidebarModel.ProjectGroup?, state: SidebarListState, nowMs: Int64) -> SidebarRowModel {
        let shell = t.shell
        let lastVisited = SidebarModel.resolveThreadLastVisitedAt(server: shell.lastVisitedAt, local: state.localVisits[shell.id])
        let isActive = shell.id == state.activeThreadId
        let isUnread = !isActive && SidebarModel.hasUnseenCompletion(latestRun: t.latestRun, lastVisitedAt: lastVisited)
        let isWoke = !isActive && SidebarModel.isWoke(t, lastVisitedAt: lastVisited, nowMs: nowMs)
        let status = SidebarModel.resolveSidebarThreadStatus(t)
        let variant: SidebarRowModel.Variant = section == .snoozed || section == .settled ? .slim : .card
        let action: SidebarRowModel.Action = section == .snoozed ? .unsnooze : section == .settled ? .unsettle : .settle
        let anchor: T3Timestamp? = section == .settled
            ? SidebarModel.resolveSettledThreadTimestamp(t) : (shell.latestUserMessageAt ?? shell.updatedAt)
        let wake = section == .snoozed ? shell.snoozedUntil?.epochMs : nil
        let working = status == .working
            ? SidebarModel.resolveWorkingStartedAt(latestRun: t.latestRun, runtime: t.runtime)?.epochMs : nil
        return SidebarRowModel(
            id: shell.id, variant: variant, action: action, section: section, title: shell.title,
            projectLabel: group?.label ?? project?.title, projectTitle: project?.title,
            branch: shell.branch, hasWorktree: !(shell.worktreePath ?? "").isEmpty,
            status: status,
            topStatus: SidebarModel.resolveSidebarV2TopStatus(status: status, isUnread: isUnread, isWoke: isWoke),
            isGoal: shell.goal?.status == .active,
            isUnread: isUnread, isWoke: isWoke, isPinned: shell.pinnedAt != nil,
            recedes: SidebarModel.shouldRecedeSidebarThread(status: status, isUnread: isUnread, isWoke: isWoke,
                                                            isActive: isActive, isSelected: false),
            isActive: isActive, isRegeneratingTitle: shell.titleRegeneration != nil,
            timeLabel: SidebarModel.threadTimeLabel(t, section: section, nowMs: nowMs),
            snoozeLabel: wake.map { snoozeWakeLabel(wakeMs: $0, nowMs: nowMs) },
            workingStartedMs: working,
            providerIcon: providerDriver(shell.runtimeInstanceId),
            timeAnchorMs: anchor?.epochMs, snoozeWakeMs: wake)
    }

    /// `snoozeWakeLabel` (packages/client-runtime/src/state/threadSettled.ts:310-319).
    public static func snoozeWakeLabel(wakeMs: Int64, nowMs: Int64) -> String {
        let remaining = Double(wakeMs - nowMs)
        if remaining <= 0 { return "now" }
        if remaining < 3_600_000 { return "\(max(1, Int((remaining / 60_000).rounded(.up))))m" }
        if remaining < 86_400_000 { return "\(Int((remaining / 3_600_000).rounded(.up)))h" }
        return "\(Int((remaining / 86_400_000).rounded(.up)))d"
    }

    /// The provider glyph for an instance id. T3 resolves the driver from the server's provider list;
    /// the shell only carries instance ids, which default to the driver name.
    // ponytail: guesses the driver from the instance id; read the server config's provider entries when it lands
    static func providerDriver(_ instance: String) -> String {
        let id = instance.lowercased()
        if id.contains("codex") || id.contains("openai") { return "codex" }
        if id.contains("cursor") { return "cursor" }
        return "claude"
    }

    // MARK: Refresh

    /// The earliest moment after `nowMs` at which any of these rows' labels change, or nil if none can.
    /// Relative times step at the minute, hour and day; Working counts seconds below a minute.
    public static func nextLabelChange(_ rows: [SidebarRowModel], nowMs: Int64) -> Int64? {
        var next: Int64?
        func consider(_ t: Int64) { if t > nowMs { next = min(next ?? t, t) } }
        for r in rows {
            if let wake = r.snoozeWakeMs {
                let remaining = wake - nowMs
                if remaining > 0 {
                    let unit: Int64 = remaining <= 3_600_000 ? 60_000 : remaining <= 86_400_000 ? 3_600_000 : 86_400_000
                    consider(nowMs + (remaining - 1) % unit + 1)
                }
            } else if let anchor = r.timeAnchorMs, r.topStatus == nil || r.variant == .slim {
                consider(nextRelativeStep(anchor: anchor, nowMs: nowMs))
            }
            if let start = r.workingStartedMs, r.variant == .card {
                let elapsed = max(0, nowMs - start)
                let unit: Int64 = elapsed < 60_000 ? 1_000 : 60_000
                consider(start + (elapsed / unit + 1) * unit)
            }
        }
        return next
    }

    static func nextRelativeStep(anchor: Int64, nowMs: Int64) -> Int64 {
        let diff = nowMs - anchor
        if diff < 0 { return anchor + 60_000 }
        let unit: Int64 = diff < 3_600_000 ? 60_000 : diff < 86_400_000 ? 3_600_000 : 86_400_000
        return anchor + (diff / unit + 1) * unit
    }
}

extension ThreadShell {
    /// `thread.runtime?.providerInstanceId ?? thread.modelSelection.instanceId` (Sidebar.tsx:1354).
    var runtimeInstanceId: String { modelSelection.instanceId.rawValue.isEmpty ? providerInstanceId.rawValue : modelSelection.instanceId.rawValue }
}
