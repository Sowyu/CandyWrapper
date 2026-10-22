import Foundation
import T3Protocol
import Testing
@testable import T3Store

@Suite struct ThreadCacheTests {
    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "thread-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Settled recorded threads, the biggest first.
    static func settled() throws -> [(ThreadReducer)] {
        try recordedThreadStreams("04-threads.jsonl").map(replay)
            .filter { $0.projection.map { ThreadCache.shouldPersist($0, history: ThreadHistoryMeta()) } ?? false }
            .sorted { $0.projection!.visibleTurnItems.count > $1.projection!.visibleTurnItems.count }
    }

    /// The same projection apart from `turnItems` order, which a compact snapshot changes.
    static func normalized(_ p: ThreadProjection) -> ThreadProjection {
        var p = p
        p.turnItems.sort { $0.id.rawValue < $1.id.rawValue }
        return p
    }

    @Test func roundTripGivesTheSameThread() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThreadCache(directory: dir)
        for reducer in try Self.settled() {
            let p = try #require(reducer.projection)
            let key = ThreadCache.Key(environmentId: "env-1", threadId: p.thread.id)
            let history = ThreadHistoryMeta(historyCursor: "cursor-1", hasMoreHistory: true, latestLocalTurnOrdinal: 7)
            await cache.offer(key, sequence: 42, projection: p, history: history)
            await cache.flush(key)
            let snapshot = try #require(cache.load(key))
            var loaded = ThreadReducer(threadId: p.thread.id)
            loaded.applySnapshot(snapshot)
            #expect(loaded.lastSequence == 42)
            #expect(loaded.history == history)
            #expect(Self.normalized(try #require(loaded.projection)) == Self.normalized(p))
            #expect(TimelineRows.derive(TimelineRowsInput(projection: loaded.projection!)) == TimelineRows.derive(TimelineRowsInput(projection: p)))
            // Resumes after the cached sequence instead of asking for a new snapshot.
            #expect(loaded.subscribeInput().afterSequence == 42)
        }
    }

    @Test func badFilesAreMissesAndGoAway() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThreadCache(directory: dir)
        let key = ThreadCache.Key(environmentId: "env-1", threadId: "thread-1")
        let url = cache.fileURL(key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not lzfse".utf8).write(to: url)
        #expect(cache.load(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // An id that only collides after sanitizing is a miss, not another thread's data.
        #expect(cache.fileURL(ThreadCache.Key(environmentId: "env/1", threadId: "t")) == cache.fileURL(ThreadCache.Key(environmentId: "env_1", threadId: "t")))
    }

    /// LZFSE files from before the LZ4 format go at the next write.
    @Test func aWriteRemovesOldLZFSEFiles() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try #require(try Self.settled().first?.projection)
        let cache = ThreadCache(directory: dir)
        let key = ThreadCache.Key(environmentId: "env-1", threadId: "a")
        let old = cache.fileURL(key).deletingLastPathComponent().appending(path: "b.lzfse")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 64).write(to: old)
        await cache.offer(key, sequence: 1, projection: p, history: ThreadHistoryMeta())
        await cache.flush(key)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(cache.load(key) != nil)
    }

    @Test func staysUnderItsByteLimitDroppingTheLeastRecentlyUsed() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try #require(try Self.settled().first?.projection)
        // Measure one entry, then allow room for two.
        let probe = ThreadCache(directory: dir)
        let first = ThreadCache.Key(environmentId: "env-1", threadId: "a")
        await probe.offer(first, sequence: 1, projection: p, history: ThreadHistoryMeta())
        await probe.flush(first)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: probe.fileURL(first).path)[.size] as? Int)
        let cache = ThreadCache(directory: dir, maxBytes: size * 2 + size / 2)
        // Explicit times order the files, so the test needn't wait for the file system's clock.
        func age(_ key: ThreadCache.Key, seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: cache.fileURL(key).path)
        }
        try age(first, seconds: 300)
        for (i, id) in ["b", "c"].enumerated() {
            if i == 1 { _ = cache.load(first) } // `a` was used, so `b` is now the oldest
            let key = ThreadCache.Key(environmentId: "env-1", threadId: ThreadId(id))
            await cache.offer(key, sequence: 1, projection: p, history: ThreadHistoryMeta())
            await cache.flush(key)
            if i == 0 { try age(key, seconds: 200) }
        }
        #expect(cache.load(first) != nil)
        #expect(cache.load(ThreadCache.Key(environmentId: "env-1", threadId: "b")) == nil)
        #expect(cache.load(ThreadCache.Key(environmentId: "env-1", threadId: "c")) != nil)
        // An entry over the per-thread limit is not written.
        let tiny = ThreadCache(directory: dir, maxEntryBytes: 16)
        let big = ThreadCache.Key(environmentId: "env-1", threadId: "big")
        await tiny.offer(big, sequence: 1, projection: p, history: ThreadHistoryMeta())
        await tiny.flush(big)
        #expect(tiny.load(big) == nil)
        await cache.removeEnvironment("env-1")
        #expect(cache.load(first) == nil)
    }

    /// The store fills itself from the cache, writes settled states back, skips running ones and
    /// forgets a deleted thread.
    @Test func storeRestoresWritesAndForgets() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThreadCache(directory: dir, firstWriteDelay: .zero, writeInterval: .milliseconds(10))
        let reducer = try #require(try Self.settled().first)
        var p = try #require(reducer.projection)
        let key = ThreadCache.Key(environmentId: "env-1", threadId: p.thread.id)
        let snapshot = ThreadDetailSnapshot(snapshotSequence: 9, projection: p, historyCursor: .null, hasMoreHistory: false, latestLocalTurnOrdinal: .null)

        // A running run is not persisted.
        var running = p
        running.runs[running.runs.count - 1].status = .running
        let busy = ThreadStore(threadId: p.thread.id, cache: cache, environmentId: "env-1", onChange: {})
        await busy.applySnapshot(ThreadDetailSnapshot(snapshotSequence: 9, projection: running, historyCursor: .null, hasMoreHistory: false, latestLocalTurnOrdinal: .null))
        await busy.flushCache()
        #expect(cache.load(key) == nil)

        let store = ThreadStore(threadId: p.thread.id, cache: cache, environmentId: "env-1", onChange: {})
        await store.applySnapshot(snapshot)
        await store.flushCache()
        #expect(cache.load(key)?.snapshotSequence == 9)

        let cold = ThreadStore(threadId: p.thread.id, cache: cache, environmentId: "env-1", onChange: {})
        #expect(await cold.subscribeInput().afterSequence == 9)
        p = try #require(await cold.projection)
        #expect(Self.normalized(p) == Self.normalized(reducer.projection!))
        #expect(await cold.restoreFromCache() == false) // once

        let deleted = ThreadEvent(id: "e", type: .threadDeleted, threadId: p.thread.id, runId: nil,
                                  occurredAt: T3Timestamp("2026-01-02T00:00:00.000Z"), payload: .thread(p.thread))
        await cold.apply([.event(sequence: 10, event: deleted)])
        await cold.flushCache()
        #expect(cache.load(key) == nil)
    }
}
