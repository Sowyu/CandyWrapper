import Foundation
import Testing
@testable import Features

/// #27440: at most 6 `assets.createUrl` calls at a time, and a caller cancelled while it waits gives its turn back.
@Suite struct AssetURLLimitTests {
    /// The way `MarkdownImages.signedURL` uses the limit.
    private func run<T: Sendable>(_ limit: MediaFetchQueue, _ body: @Sendable () async -> T) async -> T? {
        guard await limit.acquire() else { return nil }
        let value = await body()
        await limit.release()
        return value
    }

    actor Peak {
        var now = 0, max = 0
        func enter() { now += 1; max = Swift.max(max, now) }
        func leave() { now -= 1 }
    }

    @Test func runsAtMostSixAtATime() async {
        let limit = MediaFetchQueue(limit: 6)
        let peak = Peak()
        await withTaskGroup(of: Int?.self) { group in
            for i in 0..<40 {
                group.addTask {
                    await run(limit) {
                        await peak.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        await peak.leave()
                        return i
                    }
                }
            }
            var done = 0
            for await value in group where value != nil { done += 1 }
            #expect(done == 40)
        }
        #expect(await peak.max == 6)
        #expect(await limit.inFlight == 0)
    }

    /// Opens once; every `wait` before or after that returns.
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { open = true; for waiter in waiters { waiter.resume() }; waiters = [] }
    }

    /// The earlier version slept 10 ms between steps. Under a full parallel run those sleeps stretched until the waiter
    /// started before the holder or after it finished, took a free turn and returned 2, so it failed now and then.
    /// It now waits for each state it needs.
    @Test func aCancelledWaiterGivesItsTurnBack() async {
        let limit = MediaFetchQueue(limit: 1)
        let gate = Gate()
        let hold = Task { await run(limit) { await gate.wait(); return 1 } }
        while await limit.inFlight == 0 { await Task.yield() }
        let waiter = Task { await run(limit) { 2 } }
        while await limit.queued.count == 0 { await Task.yield() }
        waiter.cancel()
        #expect(await waiter.value == nil)
        #expect(await limit.queued.count == 0)
        await gate.release()
        #expect(await hold.value == 1)
        #expect(await run(limit) { 3 } == 3)
        #expect(await limit.inFlight == 0)
    }

    /// Cancelling a running call leaves its turn to the next waiter, and waiters cancelled in any order leave the queue.
    @Test func cancellingInEveryOrderLosesNoTurn() async {
        for order in [[0, 1, 2], [2, 1, 0], [1, 0, 2], [0, 2, 1]] {
            let limit = MediaFetchQueue(limit: 1)
            let gate = Gate()
            let hold = Task { await run(limit) { await gate.wait(); return -1 } }
            while await limit.inFlight == 0 { await Task.yield() }
            var waiters: [Task<Int?, Never>] = []
            for i in 0..<3 {
                waiters.append(Task { await run(limit) { i } })
                while await limit.queued.count <= i { await Task.yield() }
            }
            for i in order { waiters[i].cancel() }
            for waiter in waiters { #expect(await waiter.value == nil) }
            hold.cancel()
            await gate.release()
            _ = await hold.value
            #expect(await run(limit) { 7 } == 7)
            #expect(await limit.inFlight == 0)
            #expect(await limit.queued.count == 0)
        }
    }

    /// A thread opened at its end: 24 images ask top down, the bottom six on screen. With every turn taken, the six on
    /// screen get the next turns, bottom up, then the rest bottom up. When the reader scrolls to the top before the
    /// turns free, the top six go first instead.
    @Test func picturesOnScreenSignFirst() async {
        for scrolledToTop in [false, true] {
            let limit = MediaFetchQueue(limit: 6, gather: .milliseconds(20))
            let tag = UUID().uuidString
            let keys = (0..<24).map { "row-\($0)-\(tag)" }
            for (row, key) in keys.enumerated() { MediaPriority.set(key, visible: row >= 18, recency: Double(row)) }
            defer { keys.forEach(MediaPriority.forget) }
            for _ in 0..<6 { #expect(await limit.acquire("hold-\(tag)")) }
            final class Log: @unchecked Sendable { let lock = NSLock(); var rows: [Int] = [] }
            let log = Log()
            var waiters: [Task<Void, Never>] = []
            for (row, key) in keys.enumerated() {
                // Each keeps its turn, so the test frees one turn at a time and the log is the hand-out order.
                waiters.append(Task {
                    guard await limit.acquire(key) else { return }
                    log.lock.withLock { log.rows.append(row) }
                })
                while await limit.queued.count <= row { await Task.yield() }
            }
            if scrolledToTop {
                for (row, key) in keys.enumerated() { MediaPriority.set(key, visible: row < 6, recency: Double(row)) }
            }
            for handed in 1...24 {
                await limit.release()
                while log.lock.withLock({ log.rows.count }) < handed { await Task.yield() }
            }
            for waiter in waiters { await waiter.value }
            for _ in 0..<6 { await limit.release() }
            let rows = log.lock.withLock { log.rows }
            print("image-order \(scrolledToTop ? "scrolled-to-top" : "opened-at-end") sign order by row: \(rows)")
            let onScreen = scrolledToTop ? Array((0..<6).reversed()) : Array((18..<24).reversed())
            #expect(rows.count == 24)
            #expect(Array(rows.prefix(6)) == onScreen)
            #expect(Array(rows.dropFirst(6)) == (0..<24).reversed().filter { !onScreen.contains($0) })
            #expect(await limit.inFlight == 0)
        }
    }
}
