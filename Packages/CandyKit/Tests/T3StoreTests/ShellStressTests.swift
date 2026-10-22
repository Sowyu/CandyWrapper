import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Seeded stress runs of the shell stream: a fake server changes threads and projects (status,
/// settle, pin, snooze, archive, remove, new ones, repository identity enrichment, event types a
/// newer server sends) while the client's connection drops, resumes with duplicated replays,
/// reorders a few deltas, or takes a fresh snapshot. After every step the shell must hold unique
/// rows, the sidebar shelves must place every visible thread exactly once, and the change sets the
/// store folds between frames must rebuild the same rows. After catching up the client must hold
/// the server's threads and projects.
@Suite struct ShellStressTests {
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
    }

    static func iso(_ ms: Int64) -> T3Timestamp {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return T3Timestamp(f.string(from: date))
    }

    /// The server: the canonical shell and every delta it sent, in order.
    struct Server {
        var rng: RNG
        var shell: ShellSnapshot
        var log: [ShellStreamItem] = []
        var clock: Int64 = 1_780_000_000_000
        var nextThread = 0

        init(seed: UInt64) {
            rng = RNG(state: seed)
            shell = ShellSnapshot(schemaVersion: 1, snapshotSequence: 10, projects: [project("p0"), project("p1") { $0.workspaceRoot = "/w/p1" }])
            for _ in 0..<rng.int(1...12) { shell.threads.append(newThread()) }
        }

        mutating func newThread() -> ThreadShell {
            nextThread += 1
            clock += Int64(rng.int(1...60_000))
            let at = ShellStressTests.iso(clock)
            let projectId = shell.projects.isEmpty ? ProjectId("p0") : shell.projects[rng.int(0...shell.projects.count - 1)].id
            return thread("t\(nextThread)") {
                $0.projectId = projectId
                $0.createdAt = at
                $0.updatedAt = at
                $0.title = "Thread \(nextThread)"
            }
        }

        mutating func emit(_ make: (Int) -> ShellStreamItem) {
            let item = make(shell.snapshotSequence + 1)
            shell = ShellReduction.applyShellStreamEvent(shell, item)
            if case .unknown = item { shell.snapshotSequence += 1 }
            log.append(item)
        }

        /// One change, the way the server makes them.
        mutating func step() {
            clock += Int64(rng.int(1...90_000))
            let now = ShellStressTests.iso(clock)
            let roll = rng.int(0...99)
            if roll < 8 || shell.threads.isEmpty {
                let t = newThread()
                emit { .threadUpdated(sequence: $0, location: .active, thread: t) }
                return
            }
            let index = rng.int(0...shell.threads.count - 1)
            var t = shell.threads[index]
            switch roll {
            case 8..<12:
                emit { .threadRemoved(sequence: $0, location: .active, threadId: t.id) }
            case 12..<16:
                t.archivedAt = now
                emit { .threadUpdated(sequence: $0, location: .archive, thread: t) }
            case 16..<20:
                var p = project("p\(rng.int(0...4))") { $0.workspaceRoot = "/w/\(rng.int(0...4))" }
                p.updatedAt = now
                emit { .projectUpdated(sequence: $0, project: p) }
            case 20..<22:
                if let p = shell.projects.last, shell.projects.count > 1 {
                    emit { .projectRemoved(sequence: $0, projectId: p.id) }
                }
            case 22..<25:
                emit { .unknown(kind: "future.kind", sequence: $0) }
            case 25..<30:
                // An unchanged shell only moves the cursor.
                emit { .threadUpdated(sequence: $0, location: .active, thread: t) }
            default:
                switch rng.int(0...7) {
                case 0:
                    let statuses: [ThreadStatus] = [.idle, .preparing, .running, .waiting, .completed, .failed, .interrupted]
                    t.status = statuses[rng.int(0...statuses.count - 1)]
                    t.latestRunId = RunId("run-\(rng.int(1...3))")
                    t.latestRunRequestedAt = now
                    t.activeRunId = [.preparing, .running, .waiting].contains(t.status) ? t.latestRunId : nil
                    t.latestRunCompletedAt = [.completed, .failed, .interrupted].contains(t.status) ? .value(now) : .null
                case 1: t.settledOverride = t.settledOverride == .settled ? nil : .settled; t.settledAt = now
                case 2: t.pinnedAt = t.pinnedAt == nil ? now : nil; t.pinOrderKey = t.pinnedAt == nil ? nil : "a\(rng.int(0...9))"
                case 3: t.snoozedUntil = rng.chance(0.5) ? ShellStressTests.iso(clock + 3_600_000) : nil; t.snoozedAt = now
                case 4: t.lastVisitedAt = .value(now)
                case 5: t.title = "Renamed \(rng.int(0...99))"
                case 6: t.activeOrderKey = "k\(rng.int(0...99))"
                default: t.hasActionableProposedPlan.toggle(); t.interactionMode = rng.chance(0.5) ? .plan : .default
                }
                t.updatedAt = now
                emit { .threadUpdated(sequence: $0, location: .active, thread: t) }
            }
        }
    }

    /// Rows of a shell keyed by id, rebuilt only from change sets.
    struct Mirror {
        var threads: [ThreadId: ThreadShell] = [:]
        var projects: [ProjectId: ProjectShell] = [:]

        mutating func apply(_ c: ShellChangeSet, _ s: ShellSnapshot?) -> [String] {
            var problems: [String] = []
            let threads = Dictionary((s?.threads ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let projects = Dictionary((s?.projects ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in c.threadsInserted where self.threads[id] != nil { problems.append("thread \(id.rawValue) inserted twice") }
            for id in c.threadsRemoved where self.threads[id] == nil { problems.append("thread \(id.rawValue) removed but not shown") }
            for id in c.threadsInserted.union(c.threadsUpdated) { self.threads[id] = threads[id] }
            for id in c.threadsRemoved { self.threads[id] = nil }
            for id in c.projectsInserted.union(c.projectsUpdated) { self.projects[id] = projects[id] }
            for id in c.projectsRemoved { self.projects[id] = nil }
            if self.threads != threads { problems.append("change sets rebuild \(self.threads.count) threads, the shell has \(threads.count)") }
            if self.projects != projects { problems.append("change sets rebuild \(self.projects.count) projects, the shell has \(projects.count)") }
            return problems
        }
    }

    static func invariants(_ s: ShellSnapshot) -> [String] {
        var problems: [String] = []
        let ids = s.threads.map(\.id)
        if Set(ids).count != ids.count { problems.append("thread ids repeat") }
        if Set(s.projects.map(\.id)).count != s.projects.count { problems.append("project ids repeat") }
        if !Set(ids).isDisjoint(with: s.archivedThreads.map(\.id)) { problems.append("a thread is both active and archived") }
        let threads = s.threads.map { SidebarThread($0) }
        let nowMs: Int64 = 1_790_000_000_000
        for working in [false, true] {
            let shelves = SidebarModel.buildShelves(threads, capabilities: .init(threadSettlement: true, threadSnooze: true),
                                                    nowMs: nowMs, workingShelf: working)
            let placed = (shelves.pinned + shelves.active + shelves.working + shelves.snoozed + shelves.settled).map(\.id)
            let visible = SidebarModel.filterSidebarV2VisibleThreads(threads, scopedProjectIds: nil).map(\.id)
            if placed.count != Set(placed).count { problems.append("a thread sits on two shelves") }
            if Set(placed) != Set(visible) { problems.append("shelves hold \(placed.count) threads, \(visible.count) are visible") }
        }
        return problems
    }

    static func run(seed: UInt64) -> [String] {
        var server = Server(seed: seed)
        var rng = RNG(state: seed ^ 0x5EED)
        var client = ShellReducer()
        var mirror = Mirror()
        var pending: ShellChangeSet?
        var inbox: [ShellStreamItem] = []
        var connected = false
        var disordered = false
        // Deltas that arrive after a later one; the reducer drops them as stale.
        var late = Set<Int>()
        var seen = Set<Int>()
        var problems: [String] = []
        var log: [String] = []
        let steps = rng.int(20...160)
        func take() {
            guard let c = pending else { return }
            pending = nil
            problems += mirror.apply(c, client.snapshot)
        }
        func deliver(_ items: [ShellStreamItem]) {
            let c = client.apply(items)
            // Only a delivered authoritative snapshot repairs a reorder; one lost to a disconnect does not.
            for item in items {
                if case let .snapshot(snap, nil) = item { disordered = false; late = late.filter { $0 > snap.snapshotSequence } }
                if let s = item.sequence { seen.insert(s); if late.contains(s) { disordered = true } }
            }
            // A later delta moved the cursor past a late one that never arrived (lost to a disconnect):
            // a resume won't replay it, so only a snapshot repairs this too.
            if let cursor = client.afterSequence, late.contains(where: { $0 <= cursor && !seen.contains($0) }) { disordered = true }
            log.append(items.map { $0.sequence.map(String.init) ?? "\($0)".prefix(12).description }.joined(separator: ","))
            // `ShellStore.apply`: empty change sets don't publish.
            if !c.isEmpty { if pending == nil { pending = c } else { pending!.merge(c) } }
            if let s = client.snapshot { problems += invariants(s) }
            if rng.chance(0.5) { take() }
        }
        func connect(snapshot: Bool) {
            connected = true
            inbox = []
            if snapshot || client.afterSequence == nil {
                inbox = [.snapshot(server.shell, resolvedRepositoryIdentityRoots: nil)]
            } else {
                let after = client.afterSequence!
                inbox = server.log.filter { ($0.sequence ?? 0) > after - rng.int(0...3) }
            }
            inbox.append(.synchronized)
        }
        connect(snapshot: true)
        var made = 0
        while (made < steps || !inbox.isEmpty), problems.isEmpty {
            switch rng.int(0...99) {
            case 0..<35 where made < steps:
                let before = server.log.count
                server.step()
                made += 1
                if connected { inbox += server.log[before...] }
                if connected, inbox.count >= 2, rng.chance(0.05) {
                    let i = rng.int(0...inbox.count - 2)
                    inbox.swapAt(i, i + 1)
                    if let s = inbox[i + 1].sequence, let t = inbox[i].sequence, s < t { late.insert(s) }
                }
            case 35..<80 where connected && !inbox.isEmpty:
                let n = min(inbox.count, rng.int(1...6))
                deliver(Array(inbox.prefix(n)))
                inbox.removeFirst(n)
            case 80..<85:
                connected = false
                inbox = []
            case 85..<92 where !connected:
                connect(snapshot: rng.chance(0.2))
            case 92..<95 where connected:
                // An enrichment snapshot: repository identity for some roots, nothing else.
                var patch = server.shell
                let root = "/w/\(rng.int(0...4))"
                for i in patch.projects.indices where patch.projects[i].workspaceRoot == root {
                    patch.projects[i].repositoryIdentity = identity("repo-\(root)")
                }
                server.shell = ShellReduction.mergeShellSnapshotProjects(previous: server.shell, next: patch, resolvedRepositoryIdentityRoots: [root])
                // The server sends identities once; a resume does not repeat them, so this one arrives.
                inbox.append(.snapshot(patch, resolvedRepositoryIdentityRoots: [root]))
                deliver(inbox)
                inbox = []
            default:
                if !connected { connect(snapshot: false) }
            }
        }
        // Catch up: resume (or a fresh snapshot after a reorder), take everything, compare.
        connect(snapshot: disordered)
        deliver(inbox)
        take()
        guard problems.isEmpty, let mine = client.snapshot else {
            return problems.prefix(3).map { "seed \(seed): \($0)" } + ["  deliveries: " + log.suffix(8).joined(separator: " | ")]
        }
        if mine.threads.sorted(by: { $0.id.rawValue < $1.id.rawValue }) != server.shell.threads.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let a = Dictionary(mine.threads.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            let b = Dictionary(server.shell.threads.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            let differ = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.map { id in
                "\(id.rawValue) mine \(a[id].map { String(describing: $0) } ?? "none") server \(b[id].map { String(describing: $0) } ?? "none")"
            }
            problems.append("seed \(seed): threads differ from the server after catch-up: \(differ.prefix(3)); deliveries: " + log.suffix(6).joined(separator: " | "))
            if ProcessInfo.processInfo.environment["CW_STRESS_VERBOSE"] != nil {
                let ids = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
                for item in server.log {
                    switch item {
                    case .threadUpdated(let s, let l, let t) where ids.contains(t.id): problems.append("  server \(s): updated \(l?.rawValue ?? "-") \(t.title)")
                    case .threadRemoved(let s, _, let id) where ids.contains(id): problems.append("  server \(s): removed")
                    default: break
                    }
                }
                problems.append("  all deliveries: " + log.joined(separator: " | "))
            }
        }
        // A repository identity follows its root and sticks through snapshots that lack it (shellReducer.ts:58-70),
        // so a project the server re-created without one may still carry it here.
        func comparable(_ p: [ProjectShell], against other: [ProjectShell]) -> [ProjectShell] {
            let known = Dictionary(other.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            return p.map { var p = $0; if known[p.id]?.repositoryIdentity == nil { p.repositoryIdentity = nil }; return p }.sorted { $0.id.rawValue < $1.id.rawValue }
        }
        if comparable(mine.projects, against: server.shell.projects) != server.shell.projects.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let a = Dictionary(mine.projects.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            let b = Dictionary(server.shell.projects.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            let differ = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.map { id in
                "\(id.rawValue) mine \(a[id].map { "\($0.workspaceRoot) \($0.repositoryIdentity?.canonicalKey ?? "-")" } ?? "none") "
                    + "server \(b[id].map { "\($0.workspaceRoot) \($0.repositoryIdentity?.canonicalKey ?? "-")" } ?? "none")"
            }
            problems.append("seed \(seed): projects differ from the server after catch-up: \(differ); deliveries: " + log.suffix(30).joined(separator: " | "))
        }
        if mine.snapshotSequence != server.shell.snapshotSequence {
            problems.append("seed \(seed): cursor \(mine.snapshotSequence) vs \(server.shell.snapshotSequence)")
        }
        return problems
    }

    @Test func shellSurvivesReconnectsReplaysAndReorders() {
        let iterations = ProcessInfo.processInfo.environment["CW_STRESS_ITERATIONS"].flatMap(Int.init) ?? 30
        let first = ProcessInfo.processInfo.environment["CW_STRESS_SEED"].flatMap(UInt64.init) ?? 1
        var failures: [String] = []
        for seed in first..<(first + UInt64(iterations)) {
            failures += run(seed: seed)
            if failures.count > 6 { break }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    func run(seed: UInt64) -> [String] { Self.run(seed: seed) }
}
