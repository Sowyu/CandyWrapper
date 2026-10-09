import Foundation
import T3Protocol
import Testing
@testable import T3Store

private let repo = identity("github.com/example/repo")
private let other = identity("github.com/example/other")

private func merge(_ previous: ShellSnapshot?, _ next: ShellSnapshot, roots: [String]? = nil) -> ShellSnapshot {
    ShellReduction.mergeShellSnapshotProjects(previous: previous, next: next, resolvedRepositoryIdentityRoots: roots)
}

private func apply(_ snapshot: ShellSnapshot, _ item: ShellStreamItem) -> ShellSnapshot {
    ShellReduction.applyShellStreamEvent(snapshot, item)
}

private func snap(_ sequence: Int, projects: [ProjectShell], threads: [ThreadShell] = [baseThread]) -> ShellSnapshot {
    ShellSnapshot(schemaVersion: 1, snapshotSequence: sequence, threads: threads, projects: projects)
}

/// Ports of packages/client-runtime/src/state/shellReducer.test.ts ("applyShellStreamEvent").
@Suite struct ShellReducerPortTests {
    @Test func updatesAThreadInPlaceWithoutMovingSiblings() {
        let threads = ["a", "b", "c"].map { thread($0) }
        var updated = threads[1]
        updated.title = "Streaming"
        let next = apply(snap(0, projects: [baseProject], threads: threads),
                         .threadUpdated(sequence: 1, location: .active, thread: updated))
        #expect(next.threads.map(\.id) == ["a", "b", "c"])
        #expect(next.threads[1] == updated && next.threads[0] == threads[0])
    }

    @Test func keepsTheListWhenAnUpdateChangesNothing() {
        let threads = ["a", "b"].map { thread($0) }
        let next = apply(snap(0, projects: [], threads: threads),
                         .threadUpdated(sequence: 1, location: .active, thread: threads[1]))
        #expect(next.threads == threads && next.snapshotSequence == 1)
    }

    @Test func ignoresStaleProjectUpdates() {
        let current = snap(4, projects: [baseProject])
        for sequence in [3, 4] {
            let next = apply(current, .projectUpdated(sequence: sequence, project: project { $0.title = "Stale Title" }))
            #expect(next == current)
        }
    }

    @Test func appliesProjectUpdatesAndRemovals() {
        let updated = apply(baseSnapshot, .projectUpdated(sequence: 1, project: project { $0.title = "Updated" }))
        #expect(updated.projects[0].title == "Updated" && updated.snapshotSequence == 1)
        let removed = apply(updated, .projectRemoved(sequence: 2, projectId: baseProject.id))
        #expect(removed.projects.isEmpty)
    }

    @Test func keepsPriorIdentityWhenADeltaArrivesWithNull() {
        let withIdentity = apply(baseSnapshot, .projectUpdated(sequence: 1, project: project { $0.repositoryIdentity = repo }))
        #expect(withIdentity.projects[0].repositoryIdentity == repo)
        let withoutIdentity = apply(withIdentity, .projectUpdated(sequence: 2, project: project { $0.title = "Still same root" }))
        #expect(withoutIdentity.projects[0].title == "Still same root")
        #expect(withoutIdentity.projects[0].repositoryIdentity == repo)
    }

    @Test func dropsPriorIdentityAfterARootMove() {
        let withIdentity = apply(baseSnapshot, .projectUpdated(sequence: 1, project: project { $0.repositoryIdentity = repo }))
        let moved = apply(withIdentity, .projectUpdated(sequence: 2, project: project { $0.workspaceRoot = "/tmp/other-root" }))
        #expect(moved.projects[0].workspaceRoot == "/tmp/other-root" && moved.projects[0].repositoryIdentity == nil)
    }

    @Test func fullSnapshotKeepsKnownIdentity() {
        let next = merge(snap(0, projects: [project { $0.repositoryIdentity = repo }]),
                         snap(2, projects: [project { $0.title = "Refreshed" }]))
        #expect(next.projects[0].title == "Refreshed" && next.projects[0].repositoryIdentity == repo)
    }

    @Test func authoritativeLowerSequenceResetReplacesClientAheadState() {
        let previous = snap(9, projects: [project { $0.title = "Client ahead"; $0.repositoryIdentity = repo }],
                            threads: [thread { $0.title = "Local-only thread" }])
        let next = merge(previous, snap(3, projects: [project { $0.title = "Server reset" }],
                                        threads: [thread { $0.title = "Server thread" }]))
        #expect(next.snapshotSequence == 3 && next.projects[0].title == "Server reset")
        #expect(next.projects[0].repositoryIdentity == repo && next.threads[0].title == "Server thread")
    }

    @Test func clientAheadSurvivesLowerEnrichmentThenResetsOnAuthoritative() {
        let previous = snap(20, projects: [project { $0.title = "Client ahead"; $0.repositoryIdentity = repo }],
                            threads: [thread { $0.title = "Local-only thread" }])
        let server = snap(3, projects: [project { $0.title = "Server reset" }], threads: [thread { $0.title = "Server thread" }])
        let afterEnrichment = merge(previous, server, roots: [baseProject.workspaceRoot])
        #expect(afterEnrichment.snapshotSequence == 20 && afterEnrichment.projects[0].title == "Client ahead")
        #expect(afterEnrichment.projects[0].repositoryIdentity == nil)
        #expect(afterEnrichment.threads[0].title == "Local-only thread")
        let afterAuthoritative = merge(afterEnrichment, server)
        #expect(afterAuthoritative.snapshotSequence == 3 && afterAuthoritative.projects[0].title == "Server reset")
        #expect(afterAuthoritative.projects[0].repositoryIdentity == nil)
        #expect(afterAuthoritative.threads[0].title == "Server thread")
    }

    @Test func authoritativeNullRetainsIdentityThenMarkedEnrichmentClearsIt() {
        let previous = snap(9, projects: [project { $0.title = "Client ahead"; $0.repositoryIdentity = repo }],
                            threads: [thread { $0.title = "Local-only thread" }])
        let server = snap(3, projects: [project { $0.title = "Server reset" }], threads: [thread { $0.title = "Server thread" }])
        let afterAuthoritative = merge(previous, server)
        #expect(afterAuthoritative.projects[0].repositoryIdentity == repo)
        let afterEnrichment = merge(afterAuthoritative, server, roots: [baseProject.workspaceRoot])
        #expect(afterEnrichment.snapshotSequence == 3 && afterEnrichment.projects[0].title == "Server reset")
        #expect(afterEnrichment.projects[0].repositoryIdentity == nil && afterEnrichment.threads[0].title == "Server thread")
    }

    @Test func lowerEnrichmentGivesIdentityWithoutRevertingThreads() {
        let next = merge(snap(5, projects: [baseProject], threads: [thread { $0.title = "Newest title" }]),
                         snap(4, projects: [project { $0.repositoryIdentity = repo }], threads: [thread { $0.title = "Stale title" }]),
                         roots: [baseProject.workspaceRoot])
        #expect(next.snapshotSequence == 5 && next.threads[0].title == "Newest title")
        #expect(next.projects[0].repositoryIdentity == repo)
    }

    @Test func higherCompactEnrichmentIsMetadataOnly() {
        let next = merge(snap(5, projects: [baseProject], threads: [thread { $0.title = "Newest title" }]),
                         snap(8, projects: [project { $0.repositoryIdentity = repo }], threads: []),
                         roots: [baseProject.workspaceRoot])
        #expect(next.snapshotSequence == 5 && next.threads[0].title == "Newest title")
        #expect(next.projects[0].repositoryIdentity == repo)
    }

    @Test func lowerEnrichmentCannotResurrectEmptyState() {
        let next = merge(snap(7, projects: [], threads: []),
                         snap(4, projects: [project { $0.repositoryIdentity = repo }]), roots: [baseProject.workspaceRoot])
        #expect(next.snapshotSequence == 7 && next.projects.isEmpty && next.threads.isEmpty)
    }

    private var otherProject: ProjectShell {
        project("project-other") { $0.workspaceRoot = "/workspace/other"; $0.repositoryIdentity = other }
    }

    @Test func resolvedNullClearsOnlyTheMarkedRoot() {
        var otherNull = otherProject
        otherNull.repositoryIdentity = nil
        let next = merge(snap(5, projects: [project { $0.repositoryIdentity = repo }, otherProject]),
                         snap(4, projects: [baseProject, otherNull]), roots: [baseProject.workspaceRoot])
        #expect(next.snapshotSequence == 5 && next.projects.count == 2)
        #expect(next.projects[0].repositoryIdentity == nil && next.projects[1].repositoryIdentity == other)
    }

    @Test func unrelatedUnresolvedRootsRetainIdentity() {
        var otherNull = otherProject
        otherNull.repositoryIdentity = nil
        let next = merge(snap(3, projects: [project { $0.repositoryIdentity = repo }, otherProject],
                              threads: [thread { $0.title = "Current thread" }]),
                         snap(3, projects: [project { $0.repositoryIdentity = repo }, otherNull],
                              threads: [thread { $0.title = "Stale thread" }]),
                         roots: [baseProject.workspaceRoot])
        #expect(next.threads[0].title == "Current thread")
        #expect(next.projects[0].repositoryIdentity == repo && next.projects[1].repositoryIdentity == other)
    }

    @Test func clearsIdentityForSeveralRootsInOneBatch() {
        var otherNull = otherProject
        otherNull.repositoryIdentity = nil
        let next = merge(snap(3, projects: [project { $0.repositoryIdentity = repo }, otherProject]),
                         snap(3, projects: [baseProject, otherNull]),
                         roots: [baseProject.workspaceRoot, otherProject.workspaceRoot])
        #expect(next.projects.map(\.repositoryIdentity) == [nil, nil])
    }

    @Test func unmarkedLowerEnrichmentDoesNotReplaceALiveIdentity() {
        let live = identity("github.com/example/live"), stale = identity("github.com/example/stale")
        let next = merge(snap(5, projects: [project { $0.repositoryIdentity = live }]),
                         snap(4, projects: [project { $0.repositoryIdentity = stale }]), roots: [])
        #expect(next.snapshotSequence == 5 && next.projects[0].repositoryIdentity == live)
    }

    @Test func keepsArchiveDeltasOutOfTheNormalShell() {
        let archived = apply(baseSnapshot, .threadUpdated(sequence: 3, location: .archive,
                                                          thread: thread { $0.archivedAt = $0.updatedAt }))
        #expect(archived.threads.isEmpty && archived.archivedThreads.isEmpty)
        let active = apply(archived, .threadUpdated(sequence: 4, location: .active, thread: baseThread))
        #expect(active.threads.count == 1 && active.archivedThreads.isEmpty)
    }

    @Test func removesAThreadFromEitherCollection() {
        let next = apply(baseSnapshot, .threadRemoved(sequence: 5, location: .active, threadId: baseThread.id))
        #expect(next.threads.isEmpty && next.snapshotSequence == 5)
    }

    @Test func leavesUnknownFutureEventsUnchanged() {
        #expect(apply(baseSnapshot, .unknown(kind: "future.event", sequence: 99)) == baseSnapshot)
    }
}

/// The stateful reducer: cursor, change sets and recorded replays.
@Suite struct ShellReducerTests {
    @Test func replaysTheTurnRecording() throws {
        var reducer = ShellReducer()
        for chunk in try recordedShellChunks("02-turn.jsonl") { reducer.apply(chunk) }
        let state = try #require(reducer.snapshot)
        #expect(reducer.afterSequence == 70 && reducer.isSynchronized)
        #expect(state.projects.map(\.title) == ["demo-repo"])
        #expect(state.threads.map(\.title) == ["Count files"])
        #expect(state.threads[0].status == .cancelled && state.threads[0].projectId == state.projects[0].id)
        let row = SidebarThread(state.threads[0])
        #expect(SidebarModel.resolveSidebarThreadStatus(row) == .ready)
    }

    @Test func replaysTheSecondTurnRecording() throws {
        var reducer = ShellReducer()
        var statuses: [SidebarThreadStatus] = []
        for chunk in try recordedShellChunks("03-turn2.jsonl") {
            reducer.apply(chunk)
            if let t = reducer.snapshot?.threads.first(where: { $0.title == "Add notes and docstring" }) {
                statuses.append(SidebarModel.resolveSidebarThreadStatus(SidebarThread(t)))
            }
        }
        let state = try #require(reducer.snapshot)
        #expect(reducer.afterSequence == 198)
        #expect(state.projects.count == 1 && state.projects[0].title == "demo-repo")
        #expect(state.threads.count == 2 && state.threads.allSatisfy { $0.projectId == state.projects[0].id })
        #expect(state.threads.map(\.title) == ["Count files", "Add notes and docstring"])
        #expect(state.threads.map(\.status) == [.cancelled, .completed])
        // The approval pending at seq 110 and 118 shows as approval, the rest as working or ready.
        #expect(statuses.contains(.approval) && statuses.contains(.working) && statuses.last == .ready)
    }

    @Test func reportsInsertsUpdatesAndRemovals() {
        var reducer = ShellReducer()
        let first = reducer.apply([.snapshot(baseSnapshot, resolvedRepositoryIdentityRoots: nil)])
        #expect(first.threadsInserted == [baseThread.id] && first.projectsInserted == [baseProject.id])

        let second = reducer.apply([
            .threadUpdated(sequence: 1, location: .active, thread: thread { $0.title = "Renamed" }),
            .threadUpdated(sequence: 2, location: .active, thread: thread("new")),
            .threadRemoved(sequence: 3, location: .active, threadId: "new"),
            .projectUpdated(sequence: 4, project: project("p2")),
            .synchronized,
        ])
        #expect(second.threadsUpdated == [baseThread.id])
        #expect(second.threadsInserted.isEmpty && second.threadsRemoved.isEmpty)
        #expect(second.projectsInserted == ["p2"] && second.synchronized)

        let stale = reducer.apply([.threadUpdated(sequence: 2, location: .active, thread: thread { $0.title = "Old" })])
        #expect(stale.isEmpty && reducer.snapshot?.threads[0].title == "Renamed")
    }

    @Test func enrichmentDoesNotTouchThreads() {
        var reducer = ShellReducer(snapshot: snap(5, projects: [baseProject]))
        let changes = reducer.apply([
            .snapshot(snap(5, projects: [project { $0.repositoryIdentity = repo }], threads: []),
                      resolvedRepositoryIdentityRoots: [baseProject.workspaceRoot]),
        ])
        #expect(changes.projectsUpdated == [baseProject.id] && changes.threadsRemoved.isEmpty)
        #expect(reducer.snapshot?.threads.count == 1)
    }

    @Test func unknownKindsAdvanceTheCursor() {
        var reducer = ShellReducer(snapshot: baseSnapshot)
        reducer.apply([.unknown(kind: "future.event", sequence: 9), .unknown(kind: "future.marker", sequence: nil)])
        #expect(reducer.afterSequence == 9)
        reducer.apply([.unknown(kind: "future.event", sequence: 4)])
        #expect(reducer.afterSequence == 9)
    }

    @Test func deltasBeforeTheFirstSnapshotAreIgnored() {
        var reducer = ShellReducer()
        let changes = reducer.apply([.threadUpdated(sequence: 1, location: .active, thread: baseThread)])
        #expect(changes.isEmpty && reducer.afterSequence == nil)
    }

    @Test func changeSetsFoldAcrossBatches() {
        var a = ShellChangeSet()
        a.threadsInserted = ["x"]
        a.threadsRemoved = ["y"]
        var b = ShellChangeSet()
        b.threadsRemoved = ["x"]
        b.threadsInserted = ["y"]
        b.threadsUpdated = ["z"]
        a.merge(b)
        #expect(a.threadsInserted.isEmpty && a.threadsRemoved.isEmpty && a.threadsUpdated == ["y", "z"])
    }
}

@Suite struct ShellStoreTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test func coalescesABurstIntoOneSignalAndOneUpdate() async throws {
        let signals = Counter()
        let store = ShellStore(onChange: { signals.bump() })
        let chunks = try recordedShellChunks("02-turn.jsonl")
        let stream = AsyncStream<[ShellStreamItem]> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        try await store.consume(chunks: stream)
        #expect(signals.count == 1)
        let update = try #require(await store.takeUpdate())
        #expect(update.afterSequence == 70 && update.isSynchronized)
        #expect(update.changes.threadsInserted.count == 1 && update.changes.projectsInserted.count == 1)
        #expect(await store.takeUpdate() == nil)

        await store.apply([.threadRemoved(sequence: 71, location: .active, threadId: update.snapshot!.threads[0].id)])
        #expect(signals.count == 2)
        #expect(await store.takeUpdate()?.changes.threadsRemoved.count == 1)
    }
}
