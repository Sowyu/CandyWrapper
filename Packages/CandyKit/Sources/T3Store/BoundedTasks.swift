/// Runs `work` for every item with at most `limit` in flight, handing each result to `each` on the caller's actor as
/// it lands. For reads whose results are large while they live: Redesign's subagent cost read decodes each child's
/// full projection, about 80 MB at the peak for a 20 MB thread, so reading them all at once multiplied that.
public func forEachBounded<Item: Sendable, Result: Sendable>(
    _ items: [Item], limit: Int, isolation: isolated (any Actor)? = #isolation,
    work: @escaping @Sendable (Item) async -> Result, each: (Result) -> Void
) async {
    await withTaskGroup(of: Result.self) { group in
        var next = items.startIndex
        func start() {
            guard next < items.endIndex else { return }
            let item = items[next]
            next += 1
            group.addTask { await work(item) }
        }
        for _ in 0..<max(limit, 1) { start() }
        for await result in group {
            each(result)
            start()
        }
    }
}
