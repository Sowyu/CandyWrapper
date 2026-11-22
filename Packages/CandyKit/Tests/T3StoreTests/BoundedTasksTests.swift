import Testing
@testable import T3Store

struct BoundedTasksTests {
    actor Gauge {
        var now = 0, most = 0
        func enter() { now += 1; most = max(most, now) }
        func leave() { now -= 1 }
    }

    /// Never more than `limit` at once, every item done once, and a limit of 0 still runs.
    @Test(arguments: [0, 1, 2, 5, 20]) func runsAtMostLimitAtOnce(_ limit: Int) async {
        let gauge = Gauge()
        var seen: [Int] = []
        await forEachBounded(Array(0..<12), limit: limit, work: { i in
            await gauge.enter()
            try? await Task.sleep(for: .milliseconds(2))
            await gauge.leave()
            return i
        }, each: { seen.append($0) })
        #expect(seen.sorted() == Array(0..<12))
        #expect(await gauge.most <= max(limit, 1))
    }
}
