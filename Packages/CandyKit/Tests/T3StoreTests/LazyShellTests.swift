import Foundation
import Testing
import T3Protocol
@testable import T3Store

struct LazyShellTests {
    private let policy = ShellOmissions(omitIdleSubagents: true, omitOlderSettled: true)

    private func snapshot(_ sequence: Int = 10) -> ShellSnapshot {
        ShellSnapshot(schemaVersion: 2, snapshotSequence: sequence, threads: [thread("root")], projects: [baseProject],
            olderSettled: .init(before: "2026-10-20T00:00:00.000Z", asOfSequence: sequence,
                                counts: [.init(projectId: baseProject.id, count: 100)]), omissions: policy)
    }

    @Test func missingFlagsAndFamiliesGateOlderSettled() {
        #expect(ShellOmissions(config: .object([:])).payload.isEmpty)
        #expect(!ShellOmissions(config: .object(["shellOlderSettled": .bool(true)])).isPartial)
        let negotiated = ShellOmissions(config: .object([
            "shellThreadFamilies": .bool(true), "shellOlderSettled": .bool(true)]))
        #expect(negotiated == policy)
        #expect(negotiated.snapshotPath == "/api/orchestration/shell?omitIdleSubagents=1&omitOlderSettled=1")
        #expect(ShellOmissions().snapshotPath == "/api/orchestration/shell")
    }

    @Test func diskCacheCannotResumeButMatchingAuthoritativeMemoryCan() {
        var reducer = ShellReducer(snapshot: snapshot())
        #expect(!reducer.canResume(omissions: policy))
        reducer.apply([.snapshot(snapshot(), resolvedRepositoryIdentityRoots: nil)])
        #expect(reducer.canResume(omissions: policy))
        #expect(!reducer.canResume(omissions: ShellOmissions()))
        reducer.apply([.threadUpdated(sequence: 11, location: .active, thread: thread("root") { $0.title = "Live" })])
        let oldGeneration = reducer.generation
        reducer.mount(.init(snapshotSequence: 11, threads: [thread("child")]), key: "family", generation: oldGeneration)
        reducer.resumed()
        #expect(reducer.generation == oldGeneration + 1)
        #expect(reducer.afterSequence == 11)
        #expect(reducer.snapshot?.threads.first?.title == "Live")
        #expect(reducer.displaySnapshot?.threads.count == 1)
        #expect(reducer.mount(.init(snapshotSequence: 11, threads: [thread("stale")]), key: "late", generation: oldGeneration).isEmpty)
    }

    @Test func demandRowsDoNotAdvanceCursorOrEnterPersistedShell() {
        var reducer = ShellReducer()
        reducer.apply([.snapshot(snapshot(), resolvedRepositoryIdentityRoots: nil)])
        let generation = reducer.generation
        reducer.mount(.init(snapshotSequence: 20, threads: [thread("older")]), key: "page", generation: generation)
        #expect(reducer.afterSequence == 10)
        #expect(reducer.snapshot?.threads.map(\.id) == ["root"])
        #expect(Set(reducer.displaySnapshot?.threads.map(\.id) ?? []) == ["root", "older"])
    }

    @Test func supplementalUpdatesPublishWithoutWritingTheAuthoritativeCache() async throws {
        let store = ShellStore(onChange: {})
        await store.apply([.snapshot(snapshot(), resolvedRepositoryIdentityRoots: nil)])
        _ = await store.takeUpdate()
        let generation = await store.generation
        await store.mount(.init(snapshotSequence: 20, threads: [thread("child")]), key: "family", generation: generation)
        let update = try #require(await store.takeUpdate())
        #expect(!update.authoritativeChanged)
        #expect(update.snapshot?.threads.map(\.id) == ["root"])
        #expect(update.displaySnapshot?.threads.count == 2)
    }

    @Test func repeatedPageExceptionsStayUniqueAndLiveUnsettleWins() {
        var initial = snapshot()
        let old = thread("exception") { $0.settledOverride = .settled; $0.settledAt = "2026-10-19T00:00:00.000Z" }
        initial.threads.append(old)
        var reducer = ShellReducer()
        reducer.apply([.snapshot(initial, resolvedRepositoryIdentityRoots: nil)])
        let generation = reducer.generation
        reducer.mount(.init(snapshotSequence: 10, threads: [old]), key: "page1", generation: generation)
        reducer.mount(.init(snapshotSequence: 10, threads: [old]), key: "page2", generation: generation)
        #expect(reducer.displaySnapshot?.threads.filter { $0.id == old.id }.count == 1)
        var updated = old
        updated.settledOverride = .active
        reducer.apply([.threadUpdated(sequence: 11, location: .active, thread: updated)])
        #expect(reducer.displaySnapshot?.threads.filter { $0.settledOverride == .settled }.isEmpty == true)
    }

    @Test func staleFamilyCannotOverwriteLiveRowsOrResurrectDeletedRows() {
        var reducer = ShellReducer()
        reducer.apply([.snapshot(snapshot(), resolvedRepositoryIdentityRoots: nil)])
        let generation = reducer.generation
        reducer.mount(.init(snapshotSequence: 10, threads: [thread("child"), thread("deleted")]), key: "family", generation: generation)
        let changes = reducer.apply([
            .threadUpdated(sequence: 11, location: .active, thread: thread("child") { $0.title = "New" }),
            .threadRemoved(sequence: 12, location: .active, threadId: "deleted")])
        #expect(changes.threadsRemoved.contains("deleted"))
        reducer.mount(.init(snapshotSequence: 10, threads: [thread("child"), thread("deleted")]), key: "late-page", generation: generation)
        #expect(reducer.displaySnapshot?.threads.first { $0.id == "child" }?.title == "New")
        #expect(reducer.displaySnapshot?.threads.contains { $0.id == "deleted" } == false)
    }

    @Test func authoritativeResetInvalidatesReadsEvenWithLowerSequence() {
        var reducer = ShellReducer()
        reducer.apply([.snapshot(snapshot(), resolvedRepositoryIdentityRoots: nil)])
        let generation = reducer.generation
        reducer.mount(.init(snapshotSequence: 10, threads: [thread("child")]), key: "family", generation: generation)
        let change = reducer.apply([.snapshot(snapshot(1), resolvedRepositoryIdentityRoots: nil)])
        #expect(change.threadsRemoved.contains("child"))
        #expect(reducer.afterSequence == 1)
        #expect(reducer.generation == generation + 1)
        #expect(reducer.mount(.init(snapshotSequence: 20, threads: [thread("child")]), key: "late", generation: generation).isEmpty)
    }

    @Test func countsRejectRacingEventsAndPublishWithoutRowChanges() {
        var reducer = ShellReducer()
        reducer.apply([.snapshot(snapshot(), resolvedRepositoryIdentityRoots: nil)])
        let generation = reducer.generation
        reducer.apply([.threadRemoved(sequence: 11, location: .active, threadId: "not-loaded")])
        #expect(reducer.updateCounts(.init(snapshotSequence: 10, threads: [], counts: []), generation: generation).isEmpty)
        let changed = reducer.updateCounts(.init(snapshotSequence: 11, threads: [],
            counts: [.init(projectId: baseProject.id, count: 99)]), generation: generation)
        #expect(changed.metadataChanged && !changed.isEmpty)
        #expect(reducer.snapshot?.olderSettled?.counts.first?.count == 99)
    }

    @Test func projectEnrichmentKeepsDemandGenerationAndOmissionMetadata() {
        var reducer = ShellReducer()
        reducer.apply([.snapshot(snapshot(), resolvedRepositoryIdentityRoots: nil)])
        let generation = reducer.generation
        reducer.mount(.init(snapshotSequence: 10, threads: [thread("child")]), key: "family", generation: generation)
        reducer.apply([.snapshot(ShellSnapshot(schemaVersion: 2, snapshotSequence: 20, projects: [baseProject]),
                                 resolvedRepositoryIdentityRoots: [baseProject.workspaceRoot])])
        #expect(reducer.generation == generation && reducer.afterSequence == 10)
        #expect(reducer.displaySnapshot?.threads.count == 2)
        #expect(reducer.snapshot?.omissions == policy)
    }

    @Test func cachedOmissionsRoundTripThroughOptimizedEncoder() throws {
        let original = ShellCache.Entry(version: ShellCache.Entry.currentVersion, environmentId: "sandbox",
                                       savedAt: Date(), snapshot: snapshot())
        var encoder = ShellCacheEncoder()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ShellCache.Entry.self, from: encoder.encode(original))
        #expect(decoded.snapshot == original.snapshot)
        #expect(!ShellReducer(snapshot: decoded.snapshot).canResume(omissions: policy))
    }

    @Test func mergedCutsAndPartialityStayEnvironmentScoped() {
        var merged = MergedShell()
        merged.set(snapshot(), environmentId: "one")
        merged.set(snapshot(), environmentId: "two")
        let value = merged.merged(order: ["one", "two"])
        #expect(value?.partialEnvironmentIds == ["one", "two"])
        #expect(value?.olderSettledByEnvironment["one"]?.counts.first?.projectId == baseProject.id.scoped(to: "one"))
        #expect(value?.olderSettledByEnvironment["two"]?.counts.first?.count == 100)
    }
}
