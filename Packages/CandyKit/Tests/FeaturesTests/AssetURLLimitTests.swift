import Foundation
import Testing
@testable import Features

/// #27440: at most 6 `assets.createUrl` calls at a time, and a caller cancelled while it waits gives its turn back.
@Suite struct AssetURLLimitTests {
    /// The way `MarkdownImages.signedURL` uses the limit.
    private func run<T: Sendable>(_ limit: AssetURLLimit, _ body: @Sendable () async -> T) async -> T? {
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
        let limit = AssetURLLimit(limit: 6)
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

    @Test func aCancelledWaiterGivesItsTurnBack() async {
        let limit = AssetURLLimit(limit: 1)
        let hold = Task { await run(limit) { try? await Task.sleep(for: .milliseconds(100)); return 1 } }
        try? await Task.sleep(for: .milliseconds(10))
        let waiter = Task { await run(limit) { 2 } }
        try? await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        #expect(await waiter.value == nil)
        #expect(await hold.value == 1)
        #expect(await run(limit) { 3 } == 3)
        #expect(await limit.inFlight == 0)
    }
}
