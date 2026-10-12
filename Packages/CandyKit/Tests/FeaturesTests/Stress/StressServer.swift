import Foundation
import T3Protocol
@testable import T3Store

/// The server side of a stress run: the full event log of one thread, published a few events at a
/// time into the canonical projection, with T3's bounded snapshots and history pages
/// (apps/server/src/orchestration-v2/threadHistoryPaging.ts) cut from the canonical state.
final class StressServer {
    let threadId: ThreadId
    /// Every event as a stream item, sequence `base + 1 + index`.
    let items: [ThreadStreamItem]
    let sends: [Int: (id: String, text: String, intent: String?)]
    let base = 100
    private(set) var published = 0
    /// The canonical projection, fed every published event in order.
    private(set) var canonical: ThreadReducer
    /// User turns per bounded window and per history page (T3: THREAD_HISTORY_PAGE_POLICY and
    /// OLDER_THREAD_USER_TURN_LIMIT; smaller here so short scripts page too).
    var windowTurns = 2
    var pageTurns = 1

    init(script: StressThreadScript) throws {
        threadId = ThreadId(script.threadId)
        sends = script.sends
        let thread = script.thread
        var empty: [String: Any] = ["thread": thread, "updatedAt": thread["createdAt"]!]
        for key in ["runs", "attempts", "nodes", "subagents", "providerSessions", "providerThreads", "providerTurns", "runtimeRequests",
                    "messages", "plans", "turnItems", "checkpointScopes", "checkpoints", "contextHandoffs", "contextTransfers",
                    "visibleTurnItems"] {
            empty[key] = [Any]()
        }
        empty["visibleTurnItems"] = script.inherited
        let projection = try JSONDecoder().decode(ThreadProjection.self, from: JSONSerialization.data(withJSONObject: empty))
        canonical = ThreadReducer(threadId: threadId)
        canonical.applySnapshot(ThreadDetailSnapshot(snapshotSequence: base, projection: projection))
        let decoder = JSONDecoder()
        var items: [ThreadStreamItem] = []
        items.reserveCapacity(script.events.count)
        for (index, event) in script.events.enumerated() {
            let value: [String: Any] = ["kind": "event", "sequence": base + 1 + index, "event": event]
            items.append(try decoder.decode(ThreadStreamItem.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        self.items = items
    }

    var sequence: Int { base + published }
    var done: Bool { published == items.count }
    var projection: ThreadProjection { canonical.projection! }

    /// Publishes up to `count` more events and returns them.
    func publish(_ count: Int) -> [ThreadStreamItem] {
        let end = min(items.count, published + count)
        let batch = Array(items[published..<end])
        canonical.apply(batch)
        published = end
        return batch
    }

    /// The events after `sequence` that are already published (a resumed subscription's replay).
    func replay(after sequence: Int) -> [ThreadStreamItem] {
        let start = max(0, sequence - base)
        return start < published ? Array(items[start..<published]) : []
    }

    // MARK: Snapshots (threadHistoryPaging.ts:458-575)

    /// `isThreadHistoryUserTurn`: a prompt the user started, which pages count.
    static func isUserTurn(_ item: TurnItem) -> Bool {
        item.type == .userMessage && (item.inputIntent == .turnStart || item.inputIntent == .queuedTurn) && item.string("createdBy") == "user"
    }

    static func cursor(_ row: ProjectedTurnItem) -> String {
        "\(row.sourceThreadId.rawValue)|\(row.sourceItemId.rawValue)|\(row.position)"
    }

    /// `selectOlderTimelinePage`: rows before `end`, back through `turns` user turns.
    func olderPage(_ rows: [ProjectedTurnItem], end: Int, turns: Int) -> (items: [ProjectedTurnItem], cursor: String?, hasMore: Bool) {
        let end = min(max(end, 0), rows.count)
        guard end > 0 else { return ([], nil, false) }
        var selected: [ProjectedTurnItem] = []
        var userTurns = 0
        let limited = rows[..<end].contains { Self.isUserTurn($0.item) }
        for index in stride(from: end - 1, through: 0, by: -1) {
            if !selected.isEmpty, limited ? userTurns >= turns : selected.count >= 6 { break }
            selected.append(rows[index])
            if Self.isUserTurn(rows[index].item) { userTurns += 1 }
        }
        selected.reverse()
        let oldest = selected[0]
        let oldestIndex = rows.firstIndex { $0.sourceThreadId == oldest.sourceThreadId && $0.sourceItemId == oldest.sourceItemId } ?? -1
        let hasMore = oldestIndex > 0
        let renumbered = selected.enumerated().map { i, row in var row = row; row.position = i; return row }
        return (renumbered, hasMore ? Self.cursor(oldest) : nil, hasMore)
    }

    /// A snapshot of the canonical state: the whole projection (a legacy full snapshot), or T3's
    /// bounded window with its history cursor, optionally compact.
    func snapshot(bounded: Bool, compact: Bool) -> ThreadDetailSnapshot {
        let full = projection
        guard bounded else { return ThreadDetailSnapshot(snapshotSequence: sequence, projection: full) }
        let window = olderPage(full.visibleTurnItems, end: full.visibleTurnItems.count, turns: windowTurns)
        var p = full
        p.visibleTurnItems = window.items
        let threadId = full.thread.id
        let localIds = Set(window.items.filter { $0.isLocal || $0.sourceThreadId == threadId }.map(\.sourceItemId))
        let windowItems = full.turnItems.filter { localIds.contains($0.id) }
        let dependencies = full.turnItems.filter { $0.type == .runInterruptRequest && !localIds.contains($0.id) }
        p.turnItems = windowItems + dependencies
        // `messagesForBoundedProjection`.
        var keptMessages = Set(p.turnItems.compactMap(\.messageId))
        let latest = full.runs.max { $0.ordinal < $1.ordinal }
        var keptRuns = Set<RunId>()
        for run in full.runs where run.id == latest?.id || [.preparing, .starting, .running, .waiting, .queued].contains(run.status) {
            keptRuns.insert(run.id)
            if let id = run.userMessageId { keptMessages.insert(id) }
        }
        p.messages = full.messages.filter { keptMessages.contains($0.id) || ($0.runId.map(keptRuns.contains) ?? false) || $0.delegatedCompletion != nil }
        let planIds = Set(p.turnItems.compactMap { $0.type == .proposedPlan || $0.type == .todoList ? $0.string("planId") : nil })
        p.plans = full.plans.filter { $0.status == "active" || planIds.contains($0.id.rawValue) }
        let latestOrdinal = full.turnItems.map(\.ordinal).max()
        // `omitLocalVisibleTurnItems`: only when the local rows' items lead `turnItems` in row order.
        let localRows = window.items.filter { $0.isLocal || $0.sourceThreadId == threadId }.map(\.item)
        var omit = compact && !localRows.isEmpty && p.turnItems.count >= localRows.count
            && Array(p.turnItems.prefix(localRows.count)) == localRows
        if omit { p.turnItems.removeFirst(localRows.count) } else { omit = false }
        return ThreadDetailSnapshot(
            snapshotSequence: sequence, projection: p, historyCursor: window.cursor.map { .value($0) } ?? .null,
            hasMoreHistory: window.hasMore, latestLocalTurnOrdinal: latestOrdinal.map { .value($0) } ?? .null,
            turnItemsOmitLocalVisible: omit ? true : nil)
    }

    /// `selectHistoryPageFromCursor`: older rows of the canonical state before the cursor's row, or
    /// before its recorded position when that row is gone.
    func historyPage(cursor: String) -> ThreadHistoryPage {
        let rows = projection.visibleTurnItems
        let parts = cursor.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let anchor = rows.firstIndex { $0.sourceThreadId.rawValue == parts[0] && $0.sourceItemId.rawValue == parts[1] }
            ?? min(Int(parts[2]) ?? 0, rows.count)
        let page = olderPage(rows, end: anchor, turns: pageTurns)
        return ThreadHistoryPage(snapshotSequence: sequence, items: page.items, nextCursor: page.cursor, hasMoreHistory: page.hasMore)
    }
}
