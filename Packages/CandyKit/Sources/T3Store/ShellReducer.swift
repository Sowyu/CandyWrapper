import T3Protocol

/// What one batch of shell items changed, so the sidebar can update rows instead of reloading.
/// Ids are computed by diffing the touched rows before and after the batch, so a row inserted
/// and removed inside one batch shows up in no set.
public struct ShellChangeSet: Sendable, Equatable {
    public var projectsInserted: Set<ProjectId> = []
    public var projectsUpdated: Set<ProjectId> = []
    public var projectsRemoved: Set<ProjectId> = []
    public var threadsInserted: Set<ThreadId> = []
    public var threadsUpdated: Set<ThreadId> = []
    public var threadsRemoved: Set<ThreadId> = []
    /// The batch held a `synchronized` marker: the initial snapshot and replay are complete.
    public var synchronized = false
    public var metadataChanged = false

    public init() {}

    public var isEmpty: Bool {
        projectsInserted.isEmpty && projectsUpdated.isEmpty && projectsRemoved.isEmpty
            && threadsInserted.isEmpty && threadsUpdated.isEmpty && threadsRemoved.isEmpty && !synchronized && !metadataChanged
    }

    /// Folds a later change set into this one, as if both batches were one.
    public mutating func merge(_ later: ShellChangeSet) {
        Self.fold(&projectsInserted, &projectsUpdated, &projectsRemoved,
                  later.projectsInserted, later.projectsUpdated, later.projectsRemoved)
        Self.fold(&threadsInserted, &threadsUpdated, &threadsRemoved,
                  later.threadsInserted, later.threadsUpdated, later.threadsRemoved)
        synchronized = synchronized || later.synchronized
        metadataChanged = metadataChanged || later.metadataChanged
    }

    private static func fold<ID>(
        _ ins: inout Set<ID>, _ upd: inout Set<ID>, _ rem: inout Set<ID>,
        _ lIns: Set<ID>, _ lUpd: Set<ID>, _ lRem: Set<ID>
    ) {
        for id in lIns {
            // Removed earlier, back now: the row existed before both batches.
            if rem.remove(id) != nil { upd.insert(id) } else { ins.insert(id) }
        }
        for id in lUpd where !ins.contains(id) { upd.insert(id) }
        for id in lRem {
            // Inserted and removed inside the window: the UI never saw it.
            if ins.remove(id) == nil { upd.remove(id); rem.insert(id) }
        }
    }
}

/// Ports of T3's pure shell reducer functions (packages/client-runtime/src/state/shellReducer.ts).
public enum ShellReduction {
    /// Port of `retainRepositoryIdentity` (shellReducer.ts:58-70).
    static func retainRepositoryIdentity(_ previous: ProjectShell?, _ next: ProjectShell) -> ProjectShell {
        guard next.repositoryIdentity == nil, let identity = previous?.repositoryIdentity,
            previous?.workspaceRoot == next.workspaceRoot
        else { return next }
        var project = next
        project.repositoryIdentity = identity
        return project
    }

    /// Port of `mergeShellSnapshotProjects` (shellReducer.ts:93-133).
    ///
    /// Authoritative snapshots (`resolvedRepositoryIdentityRoots == nil`) replace structure and
    /// sequence even when lower, keeping a prior non-null identity for the same root. Enrichment
    /// snapshots only patch the repository identity of matching current projects.
    public static func mergeShellSnapshotProjects(
        previous: ShellSnapshot?, next: ShellSnapshot, resolvedRepositoryIdentityRoots: [String]? = nil
    ) -> ShellSnapshot {
        guard let previous else { return next }
        if let roots = resolvedRepositoryIdentityRoots {
            let resolved = Set(roots)
            let nextById = Dictionary(next.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            var merged = previous
            // Keep the array's shared storage until an identity actually changes. Refreshes often
            // resolve every root to the same value (T3 3cb13308e, shellReducer.ts:102-108).
            for i in previous.projects.indices {
                let project = previous.projects[i]
                guard let candidate = nextById[project.id], candidate.workspaceRoot == project.workspaceRoot,
                      resolved.contains(project.workspaceRoot) || project.repositoryIdentity == nil,
                      candidate.repositoryIdentity != project.repositoryIdentity
                else { continue }
                merged.projects[i].repositoryIdentity = candidate.repositoryIdentity
            }
            return merged
        }
        let previousById = Dictionary(previous.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var merged = next
        merged.projects = next.projects.map { retainRepositoryIdentity(previousById[$0.id], $0) }
        return merged
    }

    /// Port of `applyShellStreamEvent` (shellReducer.ts:136-200). Applies one delta; stale
    /// deltas (`sequence <= snapshotSequence`), snapshots, markers and unknown kinds return the
    /// snapshot unchanged.
    public static func applyShellStreamEvent(_ snapshot: ShellSnapshot, _ item: ShellStreamItem) -> ShellSnapshot {
        guard let sequence = item.sequence, sequence > snapshot.snapshotSequence else { return snapshot }
        var next = snapshot
        // ponytail: linear scans by id, add an id index if shells grow past a few thousand rows
        switch item {
        case .projectUpdated(_, let incoming):
            let index = next.projects.firstIndex { $0.id == incoming.id }
            let project = retainRepositoryIdentity(index.map { next.projects[$0] }, incoming)
            if let index { next.projects[index] = project } else { next.projects.append(project) }
        case .projectRemoved(_, let projectId):
            next.projects.removeAll { $0.id == projectId }
        case .threadUpdated(_, let location, let thread):
            if location == .active {
                if let index = next.threads.firstIndex(where: { $0.id == thread.id }) {
                    // An unchanged shell only moves the cursor.
                    if next.threads[index] == thread {
                        next.snapshotSequence = sequence
                        return next
                    }
                    next.threads[index] = thread
                } else {
                    next.threads.append(thread)
                }
            } else {
                // Older servers may send archive-located deltas here. Keep them out of the shell.
                next.threads.removeAll { $0.id == thread.id }
            }
            next.archivedThreads.removeAll { $0.id == thread.id }
        case .threadRemoved(_, _, let threadId):
            next.threads.removeAll { $0.id == threadId }
            next.archivedThreads.removeAll { $0.id == threadId }
        case .snapshot, .synchronized, .unknown:
            return snapshot
        }
        next.snapshotSequence = sequence
        return next
    }
}

/// The shell stream reducer: a snapshot, then deltas. Pure and synchronous; `ShellStore` wraps
/// it for concurrency.
public struct ShellReducer: Sendable {
    public private(set) var snapshot: ShellSnapshot?
    public private(set) var isSynchronized = false
    public private(set) var generation = 0
    private var supplemental: [String: ShellThreadRead] = [:]
    private var changedAt: [ThreadId: Int] = [:]
    public private(set) var countsInvalidatedAt = 0

    /// A verified warm resume retains authoritative rows/cursor, but demand reads belong to a new
    /// connection generation (T3 connection-runtime.md:86-89).
    @discardableResult
    public mutating func resumed() -> ShellChangeSet {
        let before = displaySnapshot?.threads ?? []
        generation += 1
        supplemental = [:]
        changedAt = [:]
        countsInvalidatedAt = snapshot?.snapshotSequence ?? 0
        var changes = ShellChangeSet()
        let after = displaySnapshot?.threads ?? []
        Self.diff(Set(before.map(\.id) + after.map(\.id)), before, after,
                  &changes.threadsInserted, &changes.threadsUpdated, &changes.threadsRemoved)
        changes.metadataChanged = true
        return changes
    }

    /// Demand reads never change the replay cursor or the cached authoritative shell.
    /// T3 5b35402623, client-runtime/state/threadFamilies.ts:69-89.
    public var displaySnapshot: ShellSnapshot? {
        guard var result = snapshot else { return nil }
        guard !supplemental.isEmpty else { return result }
        let base = Set(result.threads.map(\.id))
        var additions: [ThreadId: (Int, ThreadShell)] = [:]
        for read in supplemental.values {
            for thread in read.threads where !base.contains(thread.id) && (changedAt[thread.id] ?? -1) <= read.snapshotSequence {
                if (additions[thread.id]?.0 ?? -1) <= read.snapshotSequence { additions[thread.id] = (read.snapshotSequence, thread) }
            }
        }
        if !additions.isEmpty { result.threads += additions.values.map(\.1).sorted { $0.id.rawValue < $1.id.rawValue } }
        return result
    }

    @discardableResult
    public mutating func mount(_ read: ShellThreadRead?, key: String, generation: Int) -> ShellChangeSet {
        guard generation == self.generation, generation > 0 else { return ShellChangeSet() }
        let before = displaySnapshot?.threads ?? []
        let metadataChanged = supplemental[key] != read
        supplemental[key] = read
        let after = displaySnapshot?.threads ?? []
        var changes = ShellChangeSet()
        changes.metadataChanged = metadataChanged
        Self.diff(Set(before.map(\.id) + after.map(\.id)), before, after,
                  &changes.threadsInserted, &changes.threadsUpdated, &changes.threadsRemoved)
        return changes
    }

    public mutating func unmount(prefix: String, generation: Int) -> ShellChangeSet {
        guard generation == self.generation else { return ShellChangeSet() }
        let before = displaySnapshot?.threads ?? []
        supplemental = supplemental.filter { !$0.key.hasPrefix(prefix) }
        let after = displaySnapshot?.threads ?? []
        var changes = ShellChangeSet()
        Self.diff(Set(before.map(\.id) + after.map(\.id)), before, after,
                  &changes.threadsInserted, &changes.threadsUpdated, &changes.threadsRemoved)
        return changes
    }

    @discardableResult
    public mutating func updateCounts(_ page: OlderSettledPage, generation: Int) -> ShellChangeSet {
        var changes = ShellChangeSet()
        guard generation == self.generation, page.snapshotSequence >= countsInvalidatedAt,
              var cut = snapshot?.olderSettled, page.snapshotSequence >= cut.asOfSequence else { return changes }
        cut.counts = page.counts
        cut.asOfSequence = page.snapshotSequence
        changes.metadataChanged = snapshot?.olderSettled != cut
        snapshot?.olderSettled = cut
        return changes
    }

    public init(snapshot: ShellSnapshot? = nil) {
        self.snapshot = snapshot
    }

    /// The resume cursor for `orchestration.subscribeShell`. Nil until the first snapshot.
    public var afterSequence: Int? { snapshot?.snapshotSequence }
    public func canResume(omissions: ShellOmissions) -> Bool {
        generation > 0 && snapshot?.omissions == omissions
    }

    /// Applies a batch in order and returns what changed.
    ///
    /// Deviation from T3: an unknown item kind with a `sequence` above the cursor advances the
    /// cursor (docs/protocol.md 7.6: resume from the highest sequence seen). T3 drops it.
    @discardableResult
    public mutating func apply<S: Sequence>(_ items: S) -> ShellChangeSet where S.Element == ShellStreamItem {
        let before = snapshot
        let beforeDisplay = displaySnapshot
        var touchedProjects = Set<ProjectId>()
        var touchedThreads = Set<ThreadId>()
        var changes = ShellChangeSet()

        for item in items {
            switch item {
            case .snapshot(let incoming, let roots):
                let previous = snapshot
                if roots == nil {
                    touchedThreads.formUnion(beforeDisplay?.threads.map(\.id) ?? [])
                    generation += 1
                    supplemental = [:]
                    changedAt = [:]
                    countsInvalidatedAt = incoming.snapshotSequence
                    isSynchronized = false
                    changes.metadataChanged = true
                }
                snapshot = ShellReduction.mergeShellSnapshotProjects(
                    previous: previous, next: incoming, resolvedRepositoryIdentityRoots: roots)
                touchedProjects.formUnion((previous?.projects ?? []).map(\.id))
                touchedProjects.formUnion(incoming.projects.map(\.id))
                if roots == nil {
                    touchedThreads.formUnion((previous?.threads ?? []).map(\.id))
                    touchedThreads.formUnion(incoming.threads.map(\.id))
                }
            case .synchronized:
                isSynchronized = true
                changes.synchronized = true
            case .unknown(_, let sequence?):
                if let current = snapshot, sequence > current.snapshotSequence {
                    snapshot?.snapshotSequence = sequence
                }
            case .unknown(_, nil):
                break
            case .projectUpdated(_, let project):
                touchedProjects.insert(project.id)
                if let current = snapshot { snapshot = ShellReduction.applyShellStreamEvent(current, item) }
            case .projectRemoved(_, let projectId):
                touchedProjects.insert(projectId)
                if let current = snapshot { snapshot = ShellReduction.applyShellStreamEvent(current, item) }
            case .threadUpdated(_, _, let thread):
                if let sequence = item.sequence, sequence > (snapshot?.snapshotSequence ?? -1) {
                    changedAt[thread.id] = sequence
                    if let cut = snapshot?.olderSettled {
                        let previous = snapshot?.threads.first { $0.id == thread.id }
                        if Self.isOlderSettled(thread, before: cut.before) || previous.map({ Self.isOlderSettled($0, before: cut.before) }) == true
                            || (previous == nil && thread.lineage.relationshipToParent != .subagent) {
                            countsInvalidatedAt = sequence
                        }
                    }
                }
                touchedThreads.insert(thread.id)
                if let current = snapshot { snapshot = ShellReduction.applyShellStreamEvent(current, item) }
            case .threadRemoved(_, _, let threadId):
                if let sequence = item.sequence, sequence > (snapshot?.snapshotSequence ?? -1) {
                    changedAt[threadId] = sequence
                    countsInvalidatedAt = sequence
                }
                touchedThreads.insert(threadId)
                if let current = snapshot { snapshot = ShellReduction.applyShellStreamEvent(current, item) }
            }
        }

        Self.diff(touchedProjects, before?.projects ?? [], snapshot?.projects ?? [],
                  &changes.projectsInserted, &changes.projectsUpdated, &changes.projectsRemoved)
        Self.diff(touchedThreads, beforeDisplay?.threads ?? [], displaySnapshot?.threads ?? [],
                  &changes.threadsInserted, &changes.threadsUpdated, &changes.threadsRemoved)
        if before?.olderSettled != snapshot?.olderSettled { changes.metadataChanged = true }
        return changes
    }

    private static func diff<Row: Identifiable & Equatable>(
        _ touched: Set<Row.ID>, _ before: [Row], _ after: [Row],
        _ inserted: inout Set<Row.ID>, _ updated: inout Set<Row.ID>, _ removed: inout Set<Row.ID>
    ) {
        guard !touched.isEmpty else { return }
        let old = Dictionary(before.filter { touched.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let new = Dictionary(after.filter { touched.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for id in touched {
            switch (old[id], new[id]) {
            case (nil, _?): inserted.insert(id)
            case (_?, nil): removed.insert(id)
            case (let a?, let b?) where a != b: updated.insert(id)
            default: break
            }
        }
    }

    private static func isOlderSettled(_ thread: ThreadShell, before: String) -> Bool {
        thread.lineage.relationshipToParent != .subagent && thread.settledOverride == .settled
            && (thread.settledAt?.epochMs ?? Int64.max) < (T3Timestamp(before).epochMs ?? 0)
    }
}
