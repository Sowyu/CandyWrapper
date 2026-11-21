import Foundation

/// Where a reply image stands for loading order: on screen first, then the rest, most recent first. Markdown views
/// update it as the timeline scrolls; the fetch queue reads it each time a download slot frees.
enum MediaPriority {
    /// Not `Comparable`: a module-wide `<` overload slowed type checking of unrelated sorts past the compiler's limit.
    struct Rank: Equatable, Sendable {
        var visible: Bool
        /// Larger is more recent: lower in the timeline.
        var recency: Double
        func outranks(_ other: Rank) -> Bool { visible != other.visible ? visible : recency > other.recency }
        static let background = Rank(visible: false, recency: -.infinity)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var ranks: [String: Rank] = [:]

    static func set(_ key: String, visible: Bool, recency: Double) {
        lock.withLock { ranks[key] = Rank(visible: visible, recency: recency) }
    }

    static func rank(_ key: String) -> Rank { lock.withLock { ranks[key] } ?? .background }

    static func forget(_ key: String) { lock.withLock { ranks[key] = nil } }
}

/// Downloads of reply images over one link. Over a slow remote link parallel transfers only split the bandwidth, so a
/// few at a time puts the first picture on screen sooner without delaying the last. Waiters go in `MediaPriority` order,
/// and one cancelled while it waits gives its place back.
// ponytail: one queue for every environment; key it by environment if two remotes load images at once
actor MediaFetchQueue {
    // ponytail: a fixed 50 ms gather before the first slot; tie it to the sign round trip if fast links notice it
    static let shared = MediaFetchQueue(limit: 2, gather: .milliseconds(50))
    private let limit: Int
    /// How long a free slot waits for more requests before it picks one. A thread opens with all its images asking at
    /// once, in the order their signs came back; without the pause, the first two to sign took the slots ahead of the
    /// pictures on screen.
    private let gather: Duration
    private var gathering = false
    private var running = 0
    private var sequence = 0
    private var waiting: [(id: UUID, key: String, order: Int, resume: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int, gather: Duration = .zero) { self.limit = limit; self.gather = gather }

    /// Waits for a slot; false when the caller was cancelled before it. Pair a true with `release`.
    func acquire(_ key: String) async -> Bool {
        if Task.isCancelled { return false }
        if running < limit, waiting.isEmpty, gather == .zero { running += 1; return true }
        let id = UUID()
        sequence += 1
        let order = sequence
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                waiting.append((id, key, order, continuation))
                if running < limit { scheduleDispatch() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func scheduleDispatch() {
        guard !gathering else { return }
        gathering = true
        Task {
            try? await Task.sleep(for: gather)
            self.dispatch()
        }
    }

    /// Fills free slots with the best-ranked waiters; the earliest asked among equals.
    private func dispatch() {
        gathering = false
        while running < limit, !waiting.isEmpty {
            var best = 0
            var bestRank = MediaPriority.rank(waiting[0].key)
            for i in waiting.indices.dropFirst() {
                let rank = MediaPriority.rank(waiting[i].key)
                if rank.outranks(bestRank) || (rank == bestRank && waiting[i].order < waiting[best].order) { best = i; bestRank = rank }
            }
            running += 1
            waiting.remove(at: best).resume.resume(returning: true)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).resume.resume(returning: false)
    }

    func release() {
        running -= 1
        dispatch()
    }

    var inFlight: Int { running }
    var queued: [String] { waiting.map(\.key) }
}
