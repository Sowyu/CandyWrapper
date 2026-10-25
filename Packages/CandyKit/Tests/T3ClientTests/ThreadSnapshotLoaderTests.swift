import Foundation
import Testing
import T3Protocol
@testable import T3Client

struct ThreadSnapshotLoaderTests {
    actor Calls {
        var count = 0
        func next() { count += 1 }
    }

    @Test func unavailableRouteFallsBackWithoutRepeatingOnReconnect() async {
        let calls = Calls()
        let loader = ThreadSnapshotLoader(fetch: {
            await calls.next()
            throw EnvironmentHTTPError.status(404, nil)
        })
        #expect(await loader.load() == nil)
        #expect(await loader.load() == nil)
        #expect(await calls.count == 1)
    }

    @Test func cancellationDoesNotSeedTheStore() async throws {
        let calls = Calls()
        let loader = ThreadSnapshotLoader(fetch: {
            await calls.next()
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        })
        let task = Task { await loader.load() }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func snapshotCarriesSequenceAndPagingIntoTheLiveSubscription() async throws {
        let snapshot = try JSONDecoder().decode(ThreadDetailSnapshot.self, from: Data(#"""
        {"snapshotSequence":42,"projection":{"thread":{"id":"thread-1","title":"T"},
        "runs":[],"attempts":[],"nodes":[],"subagents":[],"providerSessions":[],"providerThreads":[],
        "providerTurns":[],"runtimeRequests":[],"messages":[],"plans":[],"turnItems":[],
        "checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],"contextTransfers":[],
        "visibleTurnItems":[],"updatedAt":"2026-01-01T00:00:00.000Z"},
        "historyCursor":"opaque","hasMoreHistory":true,"latestLocalTurnOrdinal":99}
        """#.utf8))
        let calls = Calls()
        let loader = ThreadSnapshotLoader(fetch: { await calls.next(); return snapshot })
        #expect(await loader.load() == snapshot)
        #expect(await loader.load() == nil)
        #expect(await calls.count == 1)
    }
}
