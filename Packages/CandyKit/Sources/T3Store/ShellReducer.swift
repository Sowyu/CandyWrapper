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

    public init() {}

    public var isEmpty: Bool {
        projectsInserted.isEmpty && projectsUpdated.isEmpty && projectsRemoved.isEmpty
            && threadsInserted.isEmpty && threadsUpdated.isEmpty && threadsRemoved.isEmpty && !synchronized
    }

    /// Folds a later change set into this one, as if both batches were one.
    public mutating func merge(_ later: ShellChangeSet) {
        Self.fold(&projectsInserted, &projectsUpdated, &projectsRemoved,
                  later.projectsInserted, later.projectsUpdated, later.projectsRemoved)
        Self.fold(&threadsInserted, &threadsUpdated, &threadsRemoved,
                  later.threadsInserted, later.threadsUpdated, later.threadsRemoved)
        synchronized = synchronized || later.synchronized
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
            merged.projects = previous.projects.map { project in
                guard let candidate = nextById[project.id], candidate.workspaceRoot == project.workspaceRoot
                else { return project }
                var patched = project
                if resolved.contains(project.workspaceRoot) {
                    patched.repositoryIdentity = candidate.repositoryIdentity
                } else if project.repositoryIdentity == nil, candidate.repositoryIdentity != nil {
                    patched.repositoryIdentity = candidate.repositoryIdentity
                }
                return patched
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

    public init(snapshot: ShellSnapshot? = nil) {
        self.snapshot = snapshot
    }

    /// The resume cursor for `orchestration.subscribeShell`. Nil until the first snapshot.
    public var afterSequence: Int? { snapshot?.snapshotSequence }

    /// Applies a batch in order and returns what changed.
    ///
    /// Deviation from T3: an unknown item kind with a `sequence` above the cursor advances the
    /// cursor (docs/protocol.md 7.6: resume from the highest sequence seen). T3 drops it.
    @discardableResult
    public mutating func apply<S: Sequence>(_ items: S) -> ShellChangeSet where S.Element == ShellStreamItem {
        let before = snapshot
        var touchedProjects = Set<ProjectId>()
        var touchedThreads = Set<ThreadId>()
        var changes = ShellChangeSet()

        for item in items {
            switch item {
            case .snapshot(let incoming, let roots):
                let previous = snapshot
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
                touchedThreads.insert(thread.id)
                if let current = snapshot { snapshot = ShellReduction.applyShellStreamEvent(current, item) }
            case .threadRemoved(_, _, let threadId):
                touchedThreads.insert(threadId)
                if let current = snapshot { snapshot = ShellReduction.applyShellStreamEvent(current, item) }
            }
        }

        Self.diff(touchedProjects, before?.projects ?? [], snapshot?.projects ?? [],
                  &changes.projectsInserted, &changes.projectsUpdated, &changes.projectsRemoved)
        Self.diff(touchedThreads, before?.threads ?? [], snapshot?.threads ?? [],
                  &changes.threadsInserted, &changes.threadsUpdated, &changes.threadsRemoved)
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
}
