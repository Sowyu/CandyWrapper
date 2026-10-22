import Foundation
import Testing
import T3Protocol
@testable import T3Store

struct ShellCacheTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "shellcache-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func recordedSnapshot() throws -> ShellSnapshot {
        var reducer = ShellReducer()
        for chunk in try recordedShellChunks("02-turn.jsonl") { reducer.apply(chunk) }
        return try #require(reducer.snapshot)
    }

    @Test func roundTripsARecordedSnapshotAndCursor() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ShellCache(directory: dir, quietPeriod: .milliseconds(20))
        let snapshot = try recordedSnapshot()
        await cache.noteChanged(snapshot, environmentId: "env-1")
        await cache.flush()
        let entry = try #require(cache.load(environmentId: "env-1"))
        #expect(entry.snapshot == snapshot)
        #expect(entry.afterSequence == snapshot.snapshotSequence)
        #expect(cache.load(environmentId: "env-2") == nil)

        // A store seeded from the cache resumes from the cached cursor.
        let store = ShellStore(cached: entry.snapshot) {}
        #expect(await store.afterSequence == snapshot.snapshotSequence)
    }

    @Test func debouncesBurstsIntoOneWriteAfterQuiet() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ManualClock()
        let cache = ShellCache(directory: dir, quietPeriod: .seconds(2), clock: clock.clock)
        await cache.noteChanged(ShellSnapshot(schemaVersion: 1, snapshotSequence: 1), environmentId: "env")
        await waitForSleeper(clock)
        for seq in 2...5 {
            clock.advance(by: .milliseconds(300))
            await cache.noteChanged(ShellSnapshot(schemaVersion: 1, snapshotSequence: seq), environmentId: "env")
        }
        // The writer wakes 2 s after the first change, sees the last one 0.8 s old and sleeps again.
        clock.advance(by: .milliseconds(800))
        await waitForSleeper(clock, count: 2)
        #expect(cache.load(environmentId: "env") == nil, "still inside the quiet period after the last change")
        // 2 s after the last change it writes once, with the newest snapshot.
        clock.advance(by: .milliseconds(1200))
        #expect(await eventually { cache.load(environmentId: "env") != nil })
        #expect(cache.load(environmentId: "env")?.afterSequence == 5)
        #expect(clock.sleepCount == 2)
    }

    /// Waits until the writer has begun its `count`th sleep and is waiting in it.
    func waitForSleeper(_ clock: ManualClock, count: Int = 1) async {
        #expect(await eventually { clock.sleepCount == count && clock.waiting == 1 })
    }

    @Test func ignoresCorruptFilesAndSanitizesIds() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ShellCache(directory: dir)
        #expect(cache.fileURL(environmentId: "../../etc/x").deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: cache.fileURL(environmentId: "bad"))
        #expect(cache.load(environmentId: "bad") == nil)
        await cache.noteChanged(ShellSnapshot(schemaVersion: 1, snapshotSequence: 9), environmentId: "gone")
        await cache.remove(environmentId: "gone")
        await cache.flush()
        #expect(cache.load(environmentId: "gone") == nil)
    }
}
