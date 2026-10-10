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
        // The quiet period is long next to the gaps, so a loaded test machine can't stretch a gap past it.
        let cache = ShellCache(directory: dir, quietPeriod: .seconds(2))
        for seq in 1...5 {
            await cache.noteChanged(ShellSnapshot(schemaVersion: 1, snapshotSequence: seq), environmentId: "env")
            try await Task.sleep(for: .milliseconds(30))
        }
        // Still inside the quiet period after the last change: nothing written yet.
        #expect(cache.load(environmentId: "env") == nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while cache.load(environmentId: "env") == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(cache.load(environmentId: "env")?.afterSequence == 5)
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
