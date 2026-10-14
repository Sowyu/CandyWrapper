import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// The caches write without a sync, so a power loss can leave a file empty or torn. Each must read
/// such a file as a miss and recover on the next write.
struct CacheFileTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cachefile-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func replacesTheFileOwnerOnlyAndLeavesNoTemporaryFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.json")
        try CacheFile.write(Data("one".utf8), to: url)
        try CacheFile.write(Data("two".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("two".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.json"])
        // A failed write throws and leaves nothing behind.
        #expect(throws: (any Error).self) { try CacheFile.write(Data("x".utf8), to: dir.appending(path: "missing/b.json")) }
    }

    @Test func shellCacheReadsATornFileAsAMissAndTheNextSaveReplacesIt() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ShellCache(directory: dir, quietPeriod: .milliseconds(1))
        await cache.noteChanged(ShellSnapshot(schemaVersion: 1, snapshotSequence: 3), environmentId: "env")
        await cache.flush()
        let url = cache.fileURL(environmentId: "env")
        let good = try Data(contentsOf: url)
        for torn in [Data(count: good.count), good.prefix(good.count / 2), Data()] {
            try torn.write(to: url)
            #expect(cache.load(environmentId: "env") == nil)
            #expect(cache.prefetch(environmentId: "env").take() == nil)
        }
        await cache.noteChanged(ShellSnapshot(schemaVersion: 1, snapshotSequence: 4), environmentId: "env")
        await cache.flush()
        #expect(cache.load(environmentId: "env")?.afterSequence == 4)
    }

    @Test func shellCachePrefetchGivesWhatLoadGives() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ShellCache(directory: dir, quietPeriod: .milliseconds(1))
        await cache.noteChanged(ShellSnapshot(schemaVersion: 1, snapshotSequence: 7), environmentId: "env")
        await cache.flush()
        let prefetch = cache.prefetch(environmentId: "env")
        #expect(prefetch.environmentId == "env")
        #expect(prefetch.take() == cache.load(environmentId: "env"))
        // A second take returns the same entry without waiting.
        #expect(prefetch.take()?.afterSequence == 7)
        #expect(cache.prefetch(environmentId: "other").take() == nil)
    }

    @Test func threadCacheDropsATornFileAndRewritesIt() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reducer = try #require(try ThreadCacheTests.settled().first)
        let projection = try #require(reducer.projection)
        let cache = ThreadCache(directory: dir, firstWriteDelay: .zero)
        let key = ThreadCache.Key(environmentId: "env", threadId: projection.thread.id)
        await cache.offer(key, sequence: 5, projection: projection, history: reducer.history)
        await cache.flush(key)
        let url = cache.fileURL(key)
        let good = try Data(contentsOf: url)
        try good.prefix(good.count / 2).write(to: url)
        #expect(cache.load(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await cache.offer(key, sequence: 6, projection: projection, history: reducer.history)
        await cache.flush(key)
        #expect(cache.load(key)?.snapshotSequence == 6)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}
