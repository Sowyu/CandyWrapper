import Foundation
import DesignSystem
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
    /// The project's icon inputs (chosen icon, icon file).
    public var projectIcon: ProjectIconSource? = nil
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
    /// In the multi-selection (`bg-sidebar-row-selected`, Sidebar.tsx:1587-1588).
    public var isSelected = false
    /// The title is the inline rename field (Sidebar.tsx:1650-1663).
    public var isRenaming = false
    public var isRegeneratingTitle: Bool
    /// Relative time, or the settled time on the settled shelf.
    public var timeLabel: String
    /// Snoozed rows show when they come back (`snoozeWakeLabel`).
    public var snoozeLabel: String?
    /// Start of the work a Working row counts from.
    public var workingStartedMs: Int64?
    public var providerIcon: String
    /// `EnvironmentMachineKind` of a thread on another environment, nil on the primary one (Sidebar.tsx:1370-1375, 2196-2205).
    public var environmentMachine: String? = nil
    /// A scratch-project thread's machine label on line 3, when projects span environments and the
    /// thread has no branch (`scratchMachineLabelFor`, Sidebar.tsx:1375, 2167-2180).
    public var scratchMachineLabel: String? = nil
    /// The machine kind drawn before `scratchMachineLabel`.
    public var scratchMachine: String? = nil
    /// `canSnooze`: the snooze button shows only where the server would accept it (Sidebar.tsx:1540-1545).
    public var canSnooze = true
    /// Terminals of this thread running a subprocess (`useThreadRunningTerminalIds`); above 0 shows
    /// the pulsing terminal glyph.
    public var terminalProcessCount = 0
    /// Dither: the row sits under its project's header, so it leaves the project out.
    public var inProjectSection = false
    /// Dither's compact row, from `SidebarListState.dither`.
    public var dither = false

    /// The linked pull request badge (`ThreadPullRequestBadgeControl`), nil without a link.
    public var pullRequestBadge: SidebarPullRequestBadge? = nil
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
        case .request: "Request"
        case .limited: "Limited"
        case .failed: "Failed"
        case .woke: "Woke"
        case .done: "Done"
        case nil: nil
        }
    }
}

public enum SidebarShelf: String, Sendable { case working, snoozed, settled }

/// A project section's header under Dither: the group's key, name, icon and how many threads it holds.
public struct SidebarProjectHeaderModel: Equatable, Sendable {
    public var key: String
    public var label: String
    public var projectTitle: String
    public var projectIcon: ProjectIconSource?
    public var count: Int
    public var expanded: Bool
    /// The Pinned section, with a pin for its icon.
    public var isPinned = false
}

/// The environments the merged shell spans: the primary (this machine), labels and machine kinds
/// (Sidebar.tsx `primaryEnvironmentId`, `environmentLabelById`, `useEnvironmentMachines`). Thread and
/// project ids are scoped (`EnvironmentScope`), so a row's environment is its id's prefix.
public struct SidebarEnvironments: Equatable, Sendable {
    /// Nil when no environment is this machine, which marks every thread as remote, as in T3's hosted app.
    public var primaryId: String?
    public var labels: [String: String]
    /// `resolveEnvironmentMachineKind`: the server's `platform.machine`, else `server`.
    public var machines: [String: String]

    public init(primaryId: String? = nil, labels: [String: String] = [:], machines: [String: String] = [:]) {
        self.primaryId = primaryId
        self.labels = labels
        self.machines = machines
    }

    public func machine(_ environmentId: String) -> String { machines[environmentId] ?? "server" }

    /// The machine glyph for a thread row, nil for the primary environment and unscoped ids.
    public func rowMachine(_ id: ThreadId) -> String? {
        guard let env = id.environmentId, env != primaryId else { return nil }
        return machine(env)
    }

    /// `projectGroupsSpanEnvironments` (sidebarProjectGrouping.ts:29-41): badges show only then.
    public static func span(_ groups: [SidebarModel.ProjectGroup]) -> Bool {
        Set(groups.flatMap { $0.members.compactMap(\.id.environmentId) }).count > 1
    }

    /// `ProjectEnvironmentBadge` (ProjectEnvironmentBadge.tsx:15-35): the first remote member's machine and
    /// "On <labels>" or "Also on <labels>". Nil when every member is on the primary environment.
    public func badge(_ group: SidebarModel.ProjectGroup) -> (machine: String, description: String)? {
        let remote = group.members.compactMap(\.id.environmentId).filter { $0 != primaryId }
            .map { (env: $0, label: labels[$0] ?? "Remote") }
            .sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
        guard let first = remote.first else { return nil }
        var seen = Set<String>()
        let names = remote.map(\.label).filter { seen.insert($0).inserted }.joined(separator: ", ")
        return (machine(first.env), "\(remote.count < group.members.count ? "Also on" : "On") \(names)")
    }
}

/// A new-thread draft the composer keeps until its first send (T3's `DraftSessionState` plus its prompt).
public struct SidebarDraft: Equatable, Sendable {
    public var id: String
    public var projectId: ProjectId
    public var prompt: String
    public var createdAt: Date
    public init(id: String, projectId: ProjectId, prompt: String, createdAt: Date) {
        self.id = id
        self.projectId = projectId
        self.prompt = prompt
        self.createdAt = createdAt
    }
}

/// `SidebarDraftRow` (Sidebar.tsx:833-950): the project, then the prompt's first line.
public struct SidebarDraftRowModel: Equatable, Sendable {
    public var id: String
    public var projectLabel: String?
    public var projectTitle: String?
    public var projectIcon: ProjectIconSource? = nil
    public var preview: String
    public var isActive: Bool
}

/// `SidebarSearchResultRow` (Sidebar.tsx:2229-2380).
public struct SidebarSearchResultModel: Equatable, Sendable {
    public var id: ThreadId
    public var index: Int
    public var title: String
    public var projectTitle: String?
    public var projectIcon: ProjectIconSource? = nil
    public var timeLabel: String
    /// The server's message match, shown as the "You:" or "Agent:" excerpt.
    public var match: ThreadSearchMatch?
    public var query: String
    /// `aria-selected`: the keyboard and pointer highlight.
    public var isHighlighted: Bool
    public var isActive: Bool
}

public enum SidebarItem: Equatable, Sendable {
    case row(SidebarRowModel)
    /// "Settled (N)" collapsed, "Settled" expanded (Sidebar.tsx:5457-5499).
    case shelfHeader(SidebarShelf, label: String, expanded: Bool)
    /// "Show N more" under an expanded settled shelf (Sidebar.tsx:5531-5542).
    case showMore(count: Int)
    case draft(SidebarDraftRowModel)
    /// `sidebar-draft-divider` under the draft rows (Sidebar.tsx:1059-1063).
    case draftDivider
    case searchResult(SidebarSearchResultModel)
    /// The centered status line: "No threads found" while searching (Sidebar.tsx:5202-5209), or the
    /// list's empty state (Sidebar.tsx:5548-5575).
    case emptyText(String, search: Bool)
    /// "No projects yet" with its Add project button (Sidebar.tsx:5556-5569).
    case noProjects
    /// Dither (after Capy): a project's own section over its unpinned threads, collapsible.
    case projectHeader(SidebarProjectHeaderModel)

    public var key: String {
        switch self {
        case .row(let r): "thread:\(r.id.rawValue)"
        case .shelfHeader(let shelf, _, _): "shelf:\(shelf.rawValue)"
        case .showMore: "show-more"
        case .draft(let d): "draft:\(d.id)"
        case .draftDivider: "draft-divider"
        case .searchResult(let r): "search:\(r.id.rawValue)"
        case .emptyText, .noProjects: "empty"
        case .projectHeader(let h): "project:\(h.key)"
        }
    }

    /// Kind for view recycling.
    var kind: Kind {
        switch self {
        case .row(let r): r.variant == .card ? .card : .slim
        case .shelfHeader: .shelf
        case .showMore: .showMore
        case .draft: .draft
        case .draftDivider: .divider
        case .searchResult: .searchResult
        case .emptyText: .emptyText
        case .noProjects: .noProjects
        case .projectHeader: .projectHeader
        }
    }

    enum Kind: CaseIterable { case card, slim, shelf, showMore, draft, divider, searchResult, emptyText, noProjects, projectHeader }

    /// Rows the keyboard can land on.
    var isFocusable: Bool { kind != .divider && kind != .emptyText }

    /// Layout height including the `py-0.5` of a card `li` (Sidebar.tsx:1955-2217). The list adds `gap-px`.
    var height: CGFloat {
        switch self {
        // Dither (after Capy): a two-line card, title then a small meta line.
        case .row(let r): r.variant == .card ? (r.dither ? 48 : 82) : 36
        case .draft: 82 // `li py-0.5` around `h-[4.875rem]`
        case .showMore: 36
        case .shelfHeader: 32
        case .draftDivider: 13 // `my-1.5 h-px`
        // `min-h-9 py-1`: a 20pt title line, plus a 16pt excerpt line when the server matched a message.
        case .searchResult(let r): r.match == nil ? 36 : 44
        case .emptyText: 64 // `py-6`, one text-xs line
        // `py-6 gap-2`: the line, then the `py-1 text-2xs` bordered button (16 + 8 + 2).
        case .noProjects: 24 + 16 + 8 + 26 + 24
        case .projectHeader: 32
        }
    }
}

/// Client-local list state: selection, shelf expansion (T3 keeps it in localStorage, default collapsed)
/// and the settled paging.
public struct SidebarListState: Equatable, Sendable {
    public var activeThreadId: ThreadId?
    public var snoozedExpanded = false
    public var settledExpanded = false
    /// The Working beta shelf (`sidebarWorkingShelfEnabled`) and whether it is open (collapsed by default).
    public var workingShelfEnabled = false
    public var workingExpanded = false
    /// When this client saw threads leave the Working shelf; the inbox orders by it. Not compared.
    public var inboxReturns: SidebarInboxReturnTracker?
    /// `SETTLED_TAIL_INITIAL_COUNT` then `+ SETTLED_TAIL_PAGE_COUNT` per "Show more".
    public var settledVisibleCount = SidebarListBuilder.settledInitialCount
    public var scopedProjectIds: Set<ProjectId>?
    /// `sidebarProjectScopeKey`, a project group key. A key whose group is gone scopes nothing, as
    /// `scopedProjectGroup` resolves to null in T3 (Sidebar.tsx:2657-2674).
    public var projectScopeKey: String?
    /// Drafts to show, the open one already frozen (see `SidebarContentView.setDrafts`).
    public var drafts: [SidebarDraft] = []
    public var activeDraftId: String?
    public var capabilities = SidebarModel.Capabilities(threadSettlement: true, threadSnooze: true)
    /// Visits recorded on this device, for servers without `lastVisitedAt`.
    public var localVisits: [ThreadId: T3Timestamp] = [:]
    public var environments = SidebarEnvironments()
    /// Scoped thread id to its terminals running a subprocess, from `subscribeTerminalMetadata`.
    public var terminalProcesses: [ThreadId: Int] = [:]
    /// `useThreadSelectionStore.selectedThreadKeys`: Cmd-click and Shift-click selection.
    public var selectedThreadIds: Set<ThreadId> = []
    /// `renamingThreadKey`.
    public var renamingThreadId: ThreadId?
    /// Each environment's scratch folder (`ServerConfig.scratchWorkspaceRoot`), normalized.
    public var scratchRoots: [String: String] = [:]
    /// `selectProjectGroupingSettings` (the Project grouping setting and its per-project overrides).
    public var grouping = SidebarModel.ProjectGrouping.current
    /// `optimisticDrop.order` (Sidebar.tsx:2851-2871): a dropped section keeps the order the drop showed
    /// while its key writes land one by one.
    public var heldOrder: (section: SidebarSection, order: [ThreadId])?
    /// Dither's project sections the user folded, by group key.
    public var collapsedProjects: Set<String> = []
    /// Dither in the sidebar's current appearance: compact rows under project sections.
    public var dither = false
    /// `sidebarProjectSortOrder` and the manual order it reads (`projectOrder`): Dither's project sections follow them.
    public var projectSortOrder = SidebarModel.SortOrder.manual
    public var projectOrder: [String] = []
    /// Threads the list leaves out: the Orchestrator's own, which sits pinned above the list. Every other row stays
    /// exactly as T3 draws it.
    public var hiddenThreadIds: Set<ThreadId> = []

    public init(activeThreadId: ThreadId? = nil) { self.activeThreadId = activeThreadId }

    public static func == (a: Self, b: Self) -> Bool {
        a.activeThreadId == b.activeThreadId && a.snoozedExpanded == b.snoozedExpanded
            && a.settledExpanded == b.settledExpanded && a.settledVisibleCount == b.settledVisibleCount
            && a.scopedProjectIds == b.scopedProjectIds && a.localVisits == b.localVisits
            && a.projectScopeKey == b.projectScopeKey && a.drafts == b.drafts && a.activeDraftId == b.activeDraftId
            && a.capabilities.threadSettlement == b.capabilities.threadSettlement
            && a.capabilities.threadSnooze == b.capabilities.threadSnooze && a.environments == b.environments
            && a.terminalProcesses == b.terminalProcesses && a.selectedThreadIds == b.selectedThreadIds
            && a.renamingThreadId == b.renamingThreadId && a.scratchRoots == b.scratchRoots && a.grouping == b.grouping
            && a.workingShelfEnabled == b.workingShelfEnabled && a.workingExpanded == b.workingExpanded
            && a.heldOrder?.section == b.heldOrder?.section && a.heldOrder?.order == b.heldOrder?.order
            && a.collapsedProjects == b.collapsedProjects && a.dither == b.dither
            && a.projectSortOrder == b.projectSortOrder && a.projectOrder == b.projectOrder
            && a.hiddenThreadIds == b.hiddenThreadIds
    }
}

public enum SidebarListBuilder {
    static let settledInitialCount = 10
    static let settledPageCount = 25

    /// `sidebarListItems` (Sidebar.tsx:3781-3829) without the drag-only markers and the beta Working shelf.
    /// What the list needs from a snapshot: project lookups, the resolved scope and the shelves.
    struct Context {
        var groups: [SidebarModel.ProjectGroup]
        var groupByProject: [ProjectId: SidebarModel.ProjectGroup] = [:]
        var projectById: [ProjectId: ProjectShell] = [:]
        var scopedGroup: SidebarModel.ProjectGroup?
        var scopedIds: Set<ProjectId>?
        var shelves: SidebarModel.Shelves
        /// `projectGroupsSpanEnvironments`: scratch rows name their machine only then.
        var spansEnvironments = false
        /// The projects and threads Dither's section order reads.
        var projects: [ProjectShell]
        var threadShells: [ThreadShell]

        init(snapshot: ShellSnapshot, state: SidebarListState, nowMs: Int64) {
            projects = snapshot.projects
            threadShells = snapshot.threads
            let groups = SidebarModel.buildProjectGroups(snapshot.projects, grouping: state.grouping, preferredEnvironmentId: state.environments.primaryId)
            self.groups = groups
            spansEnvironments = SidebarEnvironments.span(groups)
            for group in groups { for id in group.memberProjectIds { groupByProject[id] = group } }
            for p in snapshot.projects { projectById[p.id] = p }
            let scoped = state.projectScopeKey.flatMap { key in groups.first { $0.key == key } }
            scopedGroup = scoped
            let scopedIds = scoped.map { Set($0.memberProjectIds) } ?? state.scopedProjectIds
            self.scopedIds = scopedIds
            let requests = PendingSubagentRequests.byThread(snapshot.threads)
            let threads = snapshot.threads.filter { $0.archivedAt == nil && $0.deletedAt == nil }
                .map { SidebarThread($0, pendingSubagentRequest: requests[$0.id]) }
            let returns = state.inboxReturns
            shelves = SidebarModel.buildShelves(threads, scopedProjectIds: scopedIds, capabilities: state.capabilities, nowMs: nowMs,
                                                workingShelf: state.workingShelfEnabled, returnedAt: { returns?.returnedAt($0) },
                                                isWorking: { returns?.isWorking($0) ?? SidebarModel.isThreadWorking($0) })
        }
    }

    /// The scope popup's projects (`projectGroups`, Sidebar.tsx:2541-2544) in the `sidebarProjectSortOrder` setting's order.
    public static func projectScopeGroups(snapshot: ShellSnapshot?, primaryEnvironmentId: String? = nil,
                                          order: SidebarModel.SortOrder = .updatedAt, preferred: [String] = []) -> [SidebarModel.ProjectGroup] {
        guard let snapshot else { return [] }
        return SidebarModel.sortProjectGroups(
            SidebarModel.buildProjectGroups(snapshot.projects, preferredEnvironmentId: primaryEnvironmentId),
            projects: snapshot.projects, threads: snapshot.threads, order: order, preferred: preferred)
    }

    /// `sidebarListItems` (Sidebar.tsx:3781-3829) without the drag-only markers and the beta Working shelf,
    /// after the draft block (Sidebar.tsx:5393-5402), or the empty state (Sidebar.tsx:5548-5575).
    /// With a `cache`, only what changed since its last build is redone.
    public static func items(snapshot: ShellSnapshot?, state: SidebarListState, nowMs: Int64,
                             cache: SidebarListCache? = nil) -> [SidebarItem] {
        guard let snapshot else { return [] }
        let ctx = cache?.context(snapshot: snapshot, state: state, nowMs: nowMs) ?? Context(snapshot: snapshot, state: state, nowMs: nowMs)
        let drafts = draftRows(ctx, state: state)
        var items = threadItems(ctx, state: state, nowMs: nowMs, cache: cache)
        if !drafts.isEmpty { items = drafts.map(SidebarItem.draft) + [.draftDivider] + items }
        if items.isEmpty {
            if snapshot.projects.isEmpty { return [.noProjects] }
            let text = ctx.scopedGroup.map { "No threads in \($0.label) yet" } ?? "No threads yet"
            items = [.emptyText(text, search: false)]
        }
        cache?.record(items, state: state, nowMs: nowMs)
        return items
    }

    /// `SidebarDraftBlock` (Sidebar.tsx:962-1066): drafts with a prompt in the scoped projects, newest first.
    static func draftRows(_ ctx: Context, state: SidebarListState) -> [SidebarDraftRowModel] {
        state.drafts
            .filter { ctx.scopedIds?.contains($0.projectId) ?? true }
            .compactMap { d -> (SidebarDraftRowModel, Date)? in
                let preview = draftPreview(d.prompt)
                guard !preview.isEmpty else { return nil }
                let project = ctx.projectById[d.projectId]
                return (SidebarDraftRowModel(id: d.id, projectLabel: ctx.groupByProject[d.projectId]?.label ?? project?.title,
                                             projectTitle: project?.title, projectIcon: project.map(ProjectIconSource.init),
                                             preview: preview, isActive: d.id == state.activeDraftId),
                        d.createdAt)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The prompt's first line, trimmed (Sidebar.tsx:844-847).
    // ponytail: mentions show their raw text; T3 swaps context references for their labels, add with composer mentions
    static func draftPreview(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    /// Search mode (Sidebar.tsx:2893-2930, 5144-5210): every scoped thread in shelf order, title and PR
    /// matches first, then the server's message matches. No results: "Searching thread messages…" while
    /// the server search is pending, else "No threads found".
    public static func searchItems(snapshot: ShellSnapshot?, state: SidebarListState, query: String, matches: [ThreadSearchMatch],
                                   pending: Bool, highlighted: Int, nowMs: Int64) -> [SidebarItem] {
        guard let snapshot else { return [] }
        let ctx = Context(snapshot: snapshot, state: state, nowMs: nowMs)
        let s = ctx.shelves
        let matchById = Dictionary(matches.map { ($0.threadId, $0) }, uniquingKeysWith: { first, _ in first })
        let found = SidebarModel.searchSidebarThreads(s.pinned + s.active + s.working + s.snoozed + s.settled, query: query,
                                                      contentMatchIds: Set(matchById.keys))
        guard !found.isEmpty else {
            return [.emptyText(pending ? "Searching thread messages\u{2026}" : "No threads found", search: true)]
        }
        return found.enumerated().map { i, t in
            .searchResult(SidebarSearchResultModel(
                id: t.id, index: i, title: t.shell.title, projectTitle: ctx.projectById[t.shell.projectId]?.title,
                projectIcon: ctx.projectById[t.shell.projectId].map(ProjectIconSource.init),
                timeLabel: SidebarModel.threadTimeLabel(t, section: .active, nowMs: nowMs), match: matchById[t.id],
                query: query, isHighlighted: i == highlighted, isActive: t.id == state.activeThreadId))
        }
    }

    static func threadItems(_ ctx: Context, state: SidebarListState, nowMs: Int64, cache: SidebarListCache? = nil) -> [SidebarItem] {
        let shelves = ctx.shelves
        func row(_ t: SidebarThread, _ section: SidebarSection) -> SidebarItem {
            guard let cache else { return .row(rowModel(t, section: section, ctx: ctx, state: state, nowMs: nowMs)) }
            return .row(cache.row(t, section: section, ctx: ctx, state: state, nowMs: nowMs))
        }
        // `orderItemsByPreferredIds`: the held ids first, in the drop's order, then the rest as sorted.
        func held(_ threads: [SidebarThread], _ section: SidebarSection) -> [SidebarThread] {
            guard let hold = state.heldOrder, hold.section == section else { return threads }
            let byId = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let first = hold.order.compactMap { byId[$0] }
            let placed = Set(first.map(\.id))
            return first + threads.filter { !placed.contains($0.id) }
        }
        var items: [SidebarItem] = []
        if state.dither {
            // Dither (after Capy): Pinned is a section like the projects, above them.
            let pinned = held(shelves.pinned, .pinned)
            if !pinned.isEmpty {
                let expanded = !state.collapsedProjects.contains(pinnedSectionKey)
                items.append(.projectHeader(SidebarProjectHeaderModel(key: pinnedSectionKey, label: "Pinned", projectTitle: "",
                                                                      projectIcon: nil, count: pinned.count, expanded: expanded, isPinned: true)))
                for t in pinned where expanded || t.id == state.activeThreadId {
                    guard case .row(var model) = row(t, .pinned) else { continue }
                    model.inProjectSection = true
                    items.append(.row(model))
                }
            }
            items += projectSections(held(shelves.active, .active), ctx: ctx, state: state) { row($0, .active) }
        } else {
            items += held(shelves.pinned, .pinned).map { row($0, .pinned) }
            items += held(shelves.active, .active).map { row($0, .active) }
        }
        if !shelves.working.isEmpty {
            let expanded = state.workingExpanded
            items.append(.shelfHeader(.working, label: expanded ? "Working" : "Working (\(shelves.working.count))", expanded: expanded))
            // Sending folds the open thread into the shelf; its row stays (Sidebar.tsx:3040-3055).
            items += shelves.working.filter { expanded || $0.id == state.activeThreadId }.map { row($0, .working) }
        }
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

    static let pinnedSectionKey = "pinned"

    /// Dither (after Capy): the unpinned threads under one header per project, in the `sidebarProjectSortOrder` order:
    /// Manual keeps the order the user dragged, so a new turn never moves a section. The open thread stays visible
    /// in a folded section.
    static func projectSections(_ threads: [SidebarThread], ctx: Context, state: SidebarListState,
                                row: (SidebarThread) -> SidebarItem) -> [SidebarItem] {
        var byKey: [String: [SidebarThread]] = [:]
        for t in threads {
            byKey[ctx.groupByProject[t.shell.projectId]?.key ?? "project:\(t.shell.projectId.rawValue)", default: []].append(t)
        }
        var order = SidebarModel.sortProjectGroups(ctx.groups, projects: ctx.projects, threads: ctx.threadShells,
                                                   order: state.projectSortOrder, preferred: state.projectOrder).map(\.key)
        // Threads whose project has no group yet (a snapshot mid-update) follow, in thread order.
        var placed = Set(order)
        for t in threads {
            let key = ctx.groupByProject[t.shell.projectId]?.key ?? "project:\(t.shell.projectId.rawValue)"
            if placed.insert(key).inserted { order.append(key) }
        }
        var items: [SidebarItem] = []
        for key in order {
            let list = byKey[key] ?? []
            guard let first = list.first else { continue }
            let group = ctx.groupByProject[first.shell.projectId]
            let project = ctx.projectById[first.shell.projectId]
            let expanded = !state.collapsedProjects.contains(key)
            items.append(.projectHeader(SidebarProjectHeaderModel(
                key: key, label: group?.label ?? project?.title ?? "Project", projectTitle: project?.title ?? group?.label ?? "",
                projectIcon: (group?.representative ?? project).map(ProjectIconSource.init), count: list.count, expanded: expanded)))
            for t in list where expanded || t.id == state.activeThreadId {
                guard case .row(var model) = row(t) else { continue }
                model.inProjectSection = true
                items.append(.row(model))
            }
        }
        return items
    }

    /// A thread row's model with the context's project lookups, and the machine on scratch rows.
    static func rowModel(_ t: SidebarThread, section: SidebarSection, ctx: Context, state: SidebarListState, nowMs: Int64) -> SidebarRowModel {
        var model = rowModel(t, section: section, project: ctx.projectById[t.shell.projectId],
                             group: ctx.groupByProject[t.shell.projectId], state: state, nowMs: nowMs)
        if ctx.spansEnvironments, t.shell.branch == nil, let env = t.id.environmentId,
           let project = ctx.projectById[t.shell.projectId], isScratch(project, state: state) {
            model.scratchMachineLabel = state.environments.labels[env]
            model.scratchMachine = state.environments.machine(env)
        }
        return model
    }

    /// `isScratchProject`: the project sits at its environment's scratch folder.
    public static func isScratch(_ project: ProjectShell, state: SidebarListState) -> Bool {
        guard let env = project.id.environmentId, let root = state.scratchRoots[env] else { return false }
        return SidebarModel.normalizeProjectPath(project.workspaceRoot) == root
    }

    static func rowModel(_ t: SidebarThread, section: SidebarSection, project: ProjectShell?,
                         group: SidebarModel.ProjectGroup?, state: SidebarListState, nowMs: Int64) -> SidebarRowModel {
        let shell = t.shell
        let lastVisited = SidebarModel.resolveThreadLastVisitedAt(server: shell.lastVisitedAt, local: state.localVisits[shell.id])
        let isActive = shell.id == state.activeThreadId
        let isSelected = state.selectedThreadIds.contains(shell.id)
        // Not gated on the open thread: its visit clears Done (ThreadVisitTracker), while a timer wake and a
        // mark-unread on the open thread stay until the user acts (Sidebar.tsx:1262-1279).
        let isUnread = SidebarModel.hasUnseenCompletion(latestRun: t.latestRun, lastVisitedAt: lastVisited)
        let isWoke = SidebarModel.isWoke(t, lastVisitedAt: lastVisited, nowMs: nowMs)
        let status = SidebarModel.resolveSidebarThreadStatus(t)
        let variant: SidebarRowModel.Variant = section == .snoozed || section == .settled ? .slim : .card
        let action: SidebarRowModel.Action = section == .snoozed ? .unsnooze : section == .settled ? .unsettle : .settle
        let anchor: T3Timestamp? = section == .settled
            ? SidebarModel.resolveSettledThreadTimestamp(t) : (shell.latestUserMessageAt ?? shell.updatedAt)
        let wake = section == .snoozed ? shell.snoozedUntil?.epochMs : nil
        let working = status == .working
            ? SidebarModel.resolveWorkingStartedAt(latestRun: t.latestRun, runtime: t.runtime)?.epochMs : status == .waiting ? t.latestRun?.completedAt?.epochMs : nil
        var model = SidebarRowModel(
            id: shell.id, variant: variant, action: action, section: section, title: shell.title,
            projectLabel: group?.label ?? project?.title, projectTitle: project?.title, projectIcon: project.map(ProjectIconSource.init),
            branch: shell.branch, hasWorktree: !(shell.worktreePath ?? "").isEmpty,
            status: status,
            topStatus: SidebarModel.resolveSidebarV2TopStatus(status: status, isUnread: isUnread, isWoke: isWoke),
            isGoal: shell.goal?.status == .active,
            isUnread: isUnread, isWoke: isWoke, isPinned: shell.pinnedAt != nil,
            recedes: SidebarModel.shouldRecedeSidebarThread(status: status, isUnread: isUnread, isWoke: isWoke,
                                                            isActive: isActive, isSelected: isSelected),
            isActive: isActive, isSelected: isSelected, isRenaming: state.renamingThreadId == shell.id,
            isRegeneratingTitle: shell.titleRegeneration != nil,
            timeLabel: SidebarModel.threadTimeLabel(t, section: section, nowMs: nowMs),
            snoozeLabel: wake.map { snoozeWakeLabel(wakeMs: $0, nowMs: nowMs) },
            workingStartedMs: working,
            providerIcon: providerDriver(shell.runtimeInstanceId),
            environmentMachine: state.environments.rowMachine(shell.id),
            canSnooze: SidebarModel.canSnooze(t, nowMs: nowMs),
            terminalProcessCount: state.terminalProcesses[shell.id] ?? 0,
            pullRequestBadge: SidebarPullRequestBadge(shell),
            timeAnchorMs: anchor?.epochMs, snoozeWakeMs: wake)
        model.dither = state.dither
        return model
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
    // ponytail: guesses the driver from the instance id; read the server config's provider entries when it lands, and draw the account badge (ProviderBadge, Sidebar.tsx:379-401) with them
    static func providerDriver(_ instance: String) -> String {
        let id = instance.lowercased()
        if id.contains("codex") || id.contains("openai") { return "codex" }
        if id.contains("cursor") { return "cursor" }
        return "claude"
    }

    // MARK: Refresh

    /// The earliest moment after `nowMs` at which any of these rows' labels change, or nil if none can.
    /// Relative times step at the minute, hour and day; Working counts seconds below a minute.
    /// `relative: false` leaves out relative times and snooze countdowns, `working: false` Working durations.
    public static func nextLabelChange(_ rows: [SidebarRowModel], nowMs: Int64, relative: Bool = true, working: Bool = true) -> Int64? {
        var next: Int64?
        func consider(_ t: Int64) { if t > nowMs { next = min(next ?? t, t) } }
        for r in rows {
            if !relative {
                // Working durations only.
            } else if let wake = r.snoozeWakeMs {
                let remaining = wake - nowMs
                if remaining > 0 {
                    let unit: Int64 = remaining <= 3_600_000 ? 60_000 : remaining <= 86_400_000 ? 3_600_000 : 86_400_000
                    consider(nowMs + (remaining - 1) % unit + 1)
                }
            } else if let anchor = r.timeAnchorMs, r.topStatus == nil || r.variant == .slim {
                consider(nextRelativeStep(anchor: anchor, nowMs: nowMs))
            }
            if working, let start = r.workingStartedMs, r.variant == .card {
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
