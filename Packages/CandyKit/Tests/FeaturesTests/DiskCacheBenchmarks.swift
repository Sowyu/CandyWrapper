import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

// The app's disk caches on a disk of your choice, for slow-disk checks (docs/perf/README.md,
// "The app's own caches on a slow disk"). Off by default. `CW_DISK_BENCH` names a directory on the
// disk under test. `CW_DISK_BENCH_PHASE=load` only reads what an earlier run wrote, so a remount in
// between makes the reads cold:
//   CW_DISK_BENCH=/Volumes/x/bench swift test -c release -Xswiftc -enable-testing --filter DiskCacheBenchmarks

private let benchDir = ProcessInfo.processInfo.environment["CW_DISK_BENCH"].map { URL(filePath: $0, directoryHint: .isDirectory) }
private let loadOnly = ProcessInfo.processInfo.environment["CW_DISK_BENCH_PHASE"] == "load"

private func report(_ name: String, _ times: [Double]) {
    let t = times.sorted()
    let line: [String: Any] = ["name": name, "median_ms": t[t.count / 2], "min_ms": t[0], "max_ms": t[t.count - 1], "runs": t.count]
    print("PERF " + String(decoding: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self))
}

private func time(_ body: () async throws -> Void) async rethrows -> Double {
    let start = ContinuousClock.now
    try await body()
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
}

@Suite(.enabled(if: benchDir != nil), .serialized)
struct DiskCacheBenchmarks {
    /// The sidebar's 1,580-thread snapshot: the write the app makes 2 s after the shell settles, and the
    /// read it makes at launch before the first frame.
    @Test func shellCache() async throws {
        let cache = ShellCache(directory: benchDir!.appending(path: "shell", directoryHint: .isDirectory), quietPeriod: .milliseconds(1))
        let snapshot = await MainActor.run { SidebarLoadTests.loadSnapshot() }
        if !loadOnly {
            var writes: [Double] = []
            for k in 0..<5 {
                writes.append(await time {
                    await cache.noteChanged(snapshot, environmentId: "env-\(k)")
                    await cache.flush()
                })
            }
            report("disk_shell_cache_write", writes)
        }
        var loads: [Double] = []
        for k in 0..<5 {
            loads.append(await time { #expect(cache.load(environmentId: "env-\(k)")?.snapshot.threads.count == 1_580) })
        }
        report("disk_shell_cache_load", loads)
    }

    /// The huge thread's window written five times into a cache that already holds 2,000 small threads,
    /// then read back.
    @Test func threadCache() async throws {
        let (frame, threadId) = try syntheticThreadFrame(copies: 300, window: 3)
        guard case .chunk(_, let values)? = try RPCFrame.decodeServer(frame).first else { throw CancellationError() }
        var reducer = ThreadReducer(threadId: ThreadId(threadId))
        reducer.apply([try values[0].decode(as: ThreadStreamItem.self)])
        let p = try #require(reducer.projection)
        let dir = benchDir!.appending(path: "thread", directoryHint: .isDirectory)
        let cache = ThreadCache(directory: dir, maxBytes: 64 << 20)
        let keys = (0..<5).map { ThreadCache.Key(environmentId: "bench", threadId: ThreadId("huge-\($0)")) }
        if !loadOnly {
            let filler = dir.appending(path: "filler", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: filler, withIntermediateDirectories: true)
            for i in 0..<2_000 { try Data(count: 4_096).write(to: filler.appending(path: "t\(i).lzfse")) }
            var writes: [Double] = []
            for key in keys {
                writes.append(await time {
                    await cache.offer(key, sequence: 1, projection: p, history: reducer.history)
                    await cache.flush(key)
                })
            }
            report("disk_thread_cache_write", writes)
        }
        var loads: [Double] = []
        for key in keys {
            loads.append(await time { #expect(cache.load(key) != nil) })
        }
        report("disk_thread_cache_load", loads)
        if loadOnly {
            // The first write after a launch, with the cache's directory metadata still on disk.
            let cold = await time {
                await cache.offer(keys[0], sequence: 2, projection: p, history: reducer.history)
                await cache.flush(keys[0])
            }
            report("disk_thread_cache_write_cold", [cold])
        }
    }
}
