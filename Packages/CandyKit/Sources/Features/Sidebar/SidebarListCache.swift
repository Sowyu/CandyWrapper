import Foundation
import T3Protocol
import T3Store

/// What `SidebarListBuilder.items` keeps between builds so an update costs what changed, not the thread
/// count. A thread whose shell is unchanged keeps its `SidebarThread`; a shelf re-sorts only when a
/// thread entered it, left it or moved its sort key; a row model rebuilds only when its thread, its
/// selection state or one of its clock-driven fields changed. The result equals a fresh build
/// (`SidebarLoadTests.incrementalBuildsMatchFreshBuilds`).
public final class SidebarListCache {
    /// Everything every row and shelf depends on. A change rebuilds from scratch.
    struct Shared: Equatable {
        var projects: [ProjectShell]
        var grouping: SidebarModel.ProjectGrouping
        var primaryId: String?
        var scopeKey: String?
        var scopedProjectIds: Set<ProjectId>?
        var settlement: Bool
        var snooze: Bool
        var environments: SidebarEnvironments
        var scratchRoots: [String: String]
    }

    /// A thread's place: its shelf and the part of it that shelf sorts by (the id tiebreak never changes).
    struct Placement: Equatable {
        var section: SidebarSection
        var text: String?
        var ms: Int64
    }

    /// A listed thread (not archived or deleted): whether the list shows it, whether the clock can move it
    /// (it has a snooze), and its place. Small, so the per-update pass over every thread copies little.
    struct Entry {
        var visible: Bool
        var snoozed: Bool
        var placement: Placement?
    }

    /// The per-row inputs from the list state.
    struct RowFlags: Equatable {
        var isActive: Bool
        var isSelected: Bool
        var isRenaming: Bool
        var localVisit: T3Timestamp?
        var terminals: Int
    }

    struct Row {
        var thread: SidebarThread
        var section: SidebarSection
        var flags: RowFlags
        var model: SidebarRowModel
        /// The clock range the model's labels and flags hold for.
        var builtAt: Int64
        var validUntil: Int64
    }

    private var shared: Shared?
    private var context: SidebarListBuilder.Context?
    /// The last snapshot's threads, and what the list made of each, in the same order.
    private var shells: [ThreadShell] = []
    private var entries: [Entry?] = []
    private var threads: [SidebarThread?] = []
    /// Threads that may differ from the last build's, from the app; nil when unknown, which compares them all.
    private var pending: Set<ThreadId>?
    /// Whether `noteChanges` ran since the last build. A build without a note compares every thread.
    private var noted = false
    private var rows: [ThreadId: Row] = [:]

    /// Row models built since the cache was made, for tests.
    public private(set) var rowModelBuilds = 0

    /// What the last `context` call did: whether threads changed shelf or order (or everything was
    /// rebuilt), and the indices of the threads whose values changed in place.
    private var structural = true
    private var changedInPlace = Set<Int>()

    /// The rows' places in the last full list, so the next update can patch it (`patch`).
    private struct Layout {
        var state: SidebarListState
        var nowMs: Int64
        var indexById: [ThreadId: Int]
        /// Per item: the row's thread id and when its labels next change; nil and `.max` for other items.
        var ids: [ThreadId?]
        var sections: [SidebarSection?]
        var validUntil: [Int64]
    }
    private var layout: Layout?
    /// Bumped by every full list, so a holder of an older list knows a patch doesn't fit it.
    public private(set) var generation = 0

    public init() {}

    /// The next snapshot differs from the last one only in these threads (nil: unknown). Hints add up
    /// until a build uses them, so a snapshot the list skipped (while searching) is still covered.
    public func noteChanges(_ ids: Set<ThreadId>?) {
        if !noted { pending = ids; noted = true } else if let ids, pending != nil { pending?.formUnion(ids) } else { pending = nil }
    }

    /// The context for this snapshot and state, reusing what is unchanged since the last call.
    func context(snapshot: ShellSnapshot, state: SidebarListState, nowMs: Int64) -> SidebarListBuilder.Context {
        let shared = Shared(projects: snapshot.projects, grouping: state.grouping, primaryId: state.environments.primaryId,
                            scopeKey: state.projectScopeKey, scopedProjectIds: state.scopedProjectIds,
                            settlement: state.capabilities.threadSettlement, snooze: state.capabilities.threadSnooze,
                            environments: state.environments, scratchRoots: state.scratchRoots)
        // ponytail: the Working beta shelf orders by this client's return times, which move on their own; it rebuilds the shelves every time, make it incremental if the beta ships on by default
        guard shared == self.shared, var ctx = context, !state.workingShelfEnabled else {
            structural = true
            return rebuild(snapshot: snapshot, state: state, nowMs: nowMs, shared: shared)
        }
        var resort = Set<SidebarSection>()
        var changed = Set<Int>()
        var moved = false
        let new = snapshot.threads
        let hint = noted ? pending : nil
        func derive(_ i: Int, _ shell: ThreadShell, previous: Placement?) -> (Entry?, SidebarThread?) {
            rows[shell.id] = nil
            changed.insert(i)
            guard var entry = Self.entry(shell, scopedIds: ctx.scopedIds) else {
                if let previous { resort.insert(previous.section) }
                return (nil, nil)
            }
            // The old place stays until the pass below compares it with the new one.
            if entry.visible { entry.placement = previous } else if let previous { resort.insert(previous.section) }
            return (entry, SidebarThread(shell))
        }
        if Self.sameStorage(new, shells) {
            // Nothing changed (a clock tick or a state change).
        } else if Self.sameIds(new, shells) {
            // The usual update: the same threads in the same order, some with new values. Those are derived
            // again in place; with the app's hint only the hinted ones are even compared.
            for i in new.indices {
                if let hint, hint.isEmpty || !hint.contains(new[i].id) { continue }
                if shells[i] == new[i] { continue }
                (entries[i], threads[i]) = derive(i, new[i], previous: entries[i]?.placement)
            }
            shells = new
        } else {
            moved = true
            // Threads arrived, left or moved. Each keeps its derived values when its shell is unchanged.
            let oldIndex = Dictionary(shells.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            var next: [Entry?] = [], nextThreads: [SidebarThread?] = []
            next.reserveCapacity(new.count)
            nextThreads.reserveCapacity(new.count)
            for (i, shell) in new.enumerated() {
                let j = oldIndex[shell.id]
                if let j, shells[j] == shell {
                    next.append(entries[j]); nextThreads.append(threads[j])
                    if j != i { resort.insert(.snoozed) } // equal snooze times keep snapshot order
                    continue
                }
                let (entry, thread) = derive(i, shell, previous: j.flatMap { entries[$0] }?.placement)
                next.append(entry); nextThreads.append(thread)
            }
            let ids = Set(new.map(\.id))
            for (i, shell) in shells.enumerated() where !ids.contains(shell.id) {
                rows[shell.id] = nil
                if let section = entries[i]?.placement?.section { resort.insert(section) }
            }
            shells = new
            entries = next
            threads = nextThreads
        }
        pending = nil
        noted = false
        // Only a snooze moves a thread with the clock (it ends), so unchanged threads without one keep their place.
        var replaced: [Int] = []
        for i in entries.indices {
            guard let entry = entries[i], entry.visible else { continue }
            if entry.placement != nil, !entry.snoozed, !changed.contains(i) { continue }
            guard let thread = threads[i] else { continue }
            let p = Self.placement(thread, capabilities: state.capabilities, nowMs: nowMs)
            if p != entry.placement {
                entries[i]?.placement = p
                resort.insert(p.section)
                if let old = entry.placement { resort.insert(old.section) }
            } else if changed.contains(i) {
                replaced.append(i)
            }
        }
        if !resort.isEmpty || !replaced.isEmpty {
            var shelves = ctx.shelves
            for section in resort { shelves[section] = sortedShelf(section) }
            // Same shelf, same sort key: the new value takes the old one's place.
            for i in replaced {
                guard let section = entries[i]?.placement?.section, !resort.contains(section), let thread = threads[i],
                      let at = shelves[section].firstIndex(where: { $0.id == thread.id }) else { continue }
                shelves[section][at] = thread
            }
            ctx.shelves = shelves
        }
        structural = moved || !resort.isEmpty
        changedInPlace = changed
        context = ctx
        return ctx
    }

    private func rebuild(snapshot: ShellSnapshot, state: SidebarListState, nowMs: Int64, shared: Shared) -> SidebarListBuilder.Context {
        let ctx = SidebarListBuilder.Context(snapshot: snapshot, state: state, nowMs: nowMs)
        self.shared = shared
        context = ctx
        shells = snapshot.threads
        rows = [:]
        pending = nil
        noted = false
        entries = []
        threads = []
        for shell in shells {
            guard var e = Self.entry(shell, scopedIds: ctx.scopedIds) else { entries.append(nil); threads.append(nil); continue }
            let thread = SidebarThread(shell)
            if e.visible { e.placement = Self.placement(thread, capabilities: state.capabilities, nowMs: nowMs) }
            entries.append(e)
            threads.append(thread)
        }
        return ctx
    }

    private static func sameIds(_ a: [ThreadShell], _ b: [ThreadShell]) -> Bool {
        a.count == b.count && a.indices.allSatisfy { a[$0].id == b[$0].id }
    }

    private static func sameStorage(_ a: [ThreadShell], _ b: [ThreadShell]) -> Bool {
        a.count == b.count && a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
    }

    /// `Context`'s thread filter and `filterSidebarV2VisibleThreads`.
    private static func entry(_ shell: ThreadShell, scopedIds: Set<ProjectId>?) -> Entry? {
        guard shell.archivedAt == nil, shell.deletedAt == nil else { return nil }
        let visible = !SidebarModel.isSidebarSubagentThread(shell) && (scopedIds?.contains(shell.projectId) ?? true)
        return Entry(visible: visible, snoozed: shell.snoozedUntil != nil, placement: nil)
    }

    /// `buildShelves` for one shelf: its threads in snapshot order through the shelf's sort.
    private func sortedShelf(_ section: SidebarSection) -> [SidebarThread] {
        let members = entries.indices.compactMap { i in entries[i]?.placement?.section == section ? threads[i] : nil }
        switch section {
        case .pinned: return SidebarModel.sortPinnedThreadsByOrderKey(members)
        case .active, .working: return SidebarModel.sortActiveThreadsByOrderKey(members)
        case .snoozed: return SidebarModel.sortSnoozedThreads(members)
        case .settled: return SidebarModel.sortSettledThreads(members)
        }
    }

    /// The shelf `buildShelves` puts the thread on, and the key that shelf's sort reads.
    static func placement(_ t: SidebarThread, capabilities: SidebarModel.Capabilities, nowMs: Int64) -> Placement {
        let section = SidebarModel.resolveSidebarThreadSection(
            snoozed: capabilities.threadSnooze && SidebarModel.effectiveSnoozed(t, nowMs: nowMs),
            settled: capabilities.threadSettlement && t.shell.settledOverride == .settled,
            pinned: t.shell.pinnedAt != nil)
        switch section {
        case .pinned: return Placement(section: section, text: t.shell.pinOrderKey, ms: t.shell.createdAt.epochMs ?? 0)
        case .active, .working:
            return Placement(section: .active, text: t.shell.activeOrderKey, ms: SidebarModel.activeThreadAnchorTimestampMs(t.shell))
        case .snoozed: return Placement(section: section, text: nil, ms: SidebarModel.firstValidTimestampMs(t.shell.snoozedUntil))
        case .settled: return Placement(section: section, text: nil, ms: SidebarModel.resolveSettledThreadTimestamp(t)?.epochMs ?? 0)
        }
    }

    // MARK: Rows

    /// The row's model, reused while its thread, flags and clock range hold.
    func row(_ t: SidebarThread, section: SidebarSection, ctx: SidebarListBuilder.Context, state: SidebarListState,
             nowMs: Int64) -> SidebarRowModel {
        // The empty checks skip hashing the id for state most lists don't have.
        let flags = RowFlags(isActive: t.id == state.activeThreadId,
                             isSelected: !state.selectedThreadIds.isEmpty && state.selectedThreadIds.contains(t.id),
                             isRenaming: state.renamingThreadId == t.id,
                             localVisit: state.localVisits.isEmpty ? nil : state.localVisits[t.id],
                             terminals: state.terminalProcesses.isEmpty ? 0 : state.terminalProcesses[t.id] ?? 0)
        if let row = rows[t.id], row.section == section, row.flags == flags, row.builtAt <= nowMs, nowMs < row.validUntil {
            return row.model
        }
        rowModelBuilds += 1
        let model = SidebarListBuilder.rowModel(t, section: section, ctx: ctx, state: state, nowMs: nowMs)
        rows[t.id] = Row(thread: t, section: section, flags: flags, model: model, builtAt: nowMs,
                         validUntil: Self.clockValidUntil(t, model: model, nowMs: nowMs))
        return model
    }

    /// Notes where a full list put each row (`items` calls it).
    func record(_ items: [SidebarItem], state: SidebarListState, nowMs: Int64) {
        generation += 1
        var layout = Layout(state: state, nowMs: nowMs, indexById: [:], ids: [], sections: [], validUntil: [])
        layout.ids.reserveCapacity(items.count)
        layout.sections.reserveCapacity(items.count)
        layout.validUntil.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            guard case .row(let r) = item, let row = rows[r.id] else {
                layout.ids.append(nil); layout.sections.append(nil); layout.validUntil.append(.max); continue
            }
            layout.indexById[r.id] = i
            layout.ids.append(r.id)
            layout.sections.append(row.section)
            layout.validUntil.append(row.validUntil)
        }
        self.layout = layout
    }

    /// The update as changes to the last full list, when nothing moved: the rows whose thread changed in
    /// place and the rows whose labels the clock changed, by index. Nil when the list has to be built
    /// again (a thread changed shelf or order, the list state changed, or the clock went back).
    func patch(snapshot: ShellSnapshot, state: SidebarListState, nowMs: Int64) -> [(index: Int, item: SidebarItem)]? {
        guard var layout, nowMs >= layout.nowMs, state == layout.state else { return nil }
        let ctx = context(snapshot: snapshot, state: state, nowMs: nowMs)
        guard !structural else { self.layout = nil; return nil }
        // Item index to the row's current thread: changed threads from `threads`, the rest from their row.
        var due: [Int: SidebarThread] = [:]
        for i in changedInPlace {
            guard let thread = threads[i], let at = layout.indexById[thread.id] else { continue }
            due[at] = thread
        }
        for (at, until) in layout.validUntil.enumerated() where until <= nowMs && due[at] == nil {
            guard let id = layout.ids[at], let thread = rows[id]?.thread else { return nil }
            due[at] = thread
        }
        var out: [(index: Int, item: SidebarItem)] = []
        for (at, thread) in due.sorted(by: { $0.key < $1.key }) {
            guard let section = layout.sections[at] else { return nil }
            let model = row(thread, section: section, ctx: ctx, state: state, nowMs: nowMs)
            layout.validUntil[at] = rows[thread.id]?.validUntil ?? .max
            out.append((at, .row(model)))
        }
        layout.nowMs = nowMs
        self.layout = layout
        return out
    }

    /// The first moment a clock-driven field of the row can change: the time or snooze label steps,
    /// a snooze ends (Woke), or a fresh message leaves the queued-turn grace (`canSnooze`).
    static func clockValidUntil(_ t: SidebarThread, model: SidebarRowModel, nowMs: Int64) -> Int64 {
        var until = SidebarListBuilder.nextLabelChange([model], nowMs: nowMs, relative: true, working: false) ?? .max
        // `nextLabelChange` skips time labels hidden behind a status; the model holds the label anyway.
        if let anchor = model.timeAnchorMs { until = min(until, SidebarListBuilder.nextRelativeStep(anchor: anchor, nowMs: nowMs)) }
        if let wake = t.shell.snoozedUntil?.epochMs, wake > nowMs { until = min(until, wake) }
        if let message = t.shell.latestUserMessageAt?.epochMs {
            let grace = SidebarModel.queuedTurnStartGraceMs
            if nowMs < message - grace { until = min(until, message - grace) }
            else if nowMs <= message + grace { until = min(until, message + grace + 1) }
        }
        return until
    }
}

extension SidebarModel.Shelves {
    subscript(section: SidebarSection) -> [SidebarThread] {
        get {
            switch section {
            case .pinned: pinned
            case .active: active
            case .working: working
            case .snoozed: snoozed
            case .settled: settled
            }
        }
        set {
            switch section {
            case .pinned: pinned = newValue
            case .active: active = newValue
            case .working: working = newValue
            case .snoozed: snoozed = newValue
            case .settled: settled = newValue
            }
        }
    }
}
