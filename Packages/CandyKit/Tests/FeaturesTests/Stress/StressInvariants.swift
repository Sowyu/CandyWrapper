import Foundation
import T3Protocol
@testable import T3Store
@testable import Features

/// What must hold after every step of a stress run, as readable failure strings.
enum StressInvariants {
    /// The projection's own bookkeeping: unique rows numbered in order, local rows sorted by
    /// `(ordinal, id)`, every local row's item in `turnItems`, and in a complete window every
    /// visible local item shown.
    static func projection(_ p: ThreadProjection, partial: Bool) -> [String] {
        var problems: [String] = []
        var seen = Set<String>()
        for (i, row) in p.visibleTurnItems.enumerated() {
            if row.position != i { problems.append("row \(row.sourceItemId.rawValue) position \(row.position) at \(i)"); break }
            if !seen.insert("\(row.sourceThreadId.rawValue):\(row.sourceItemId.rawValue)").inserted {
                problems.append("row \(row.sourceItemId.rawValue) twice in visibleTurnItems")
            }
        }
        let local = p.visibleTurnItems.filter(\.isLocal)
        for (a, b) in zip(local, local.dropFirst())
        where a.item.ordinal > b.item.ordinal || (a.item.ordinal == b.item.ordinal && a.item.id.rawValue > b.item.id.rawValue) {
            problems.append("local rows out of order: \(a.item.id.rawValue) before \(b.item.id.rawValue)")
        }
        var itemIds = Set<TurnItemId>()
        for item in p.turnItems where !itemIds.insert(item.id).inserted { problems.append("turn item \(item.id.rawValue) twice") }
        let byId = Dictionary(p.turnItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for row in local {
            guard let item = byId[row.sourceItemId] else { problems.append("row \(row.sourceItemId.rawValue) has no turn item"); continue }
            if item != row.item { problems.append("row \(row.sourceItemId.rawValue) differs from its turn item") }
        }
        if !partial {
            let isVisible = ThreadReduction.visibility(runs: p.runs, attempts: p.attempts, items: p.turnItems)
            let shown = Set(local.map(\.sourceItemId))
            for item in p.turnItems where isVisible(item) && !shown.contains(item.id) {
                problems.append("visible item \(item.id.rawValue) missing from the rows")
            }
            for row in local where !isVisible(row.item) { problems.append("hidden item \(row.sourceItemId.rawValue) still shown") }
        }
        return problems
    }

    static func kind(_ row: TimelineRow) -> String {
        switch row.kind {
        case .message(let m, _, _, _, _, _): m.role == .user ? "user" : "assistant"
        case .assistantMeta: "meta"
        case .work(_, true, _): "details"
        case .work: "work"
        case .workLive: "live"
        case .working: "working"
        case .thinking: "thinking"
        case .workToggle: "toggle"
        case .turnFold: "fold"
        case .attemptFold: "attempt-fold"
        case .contextCompaction: "compaction"
        case .event(let p, _, _): "event-\(p.item.type.rawValue)"
        case .proposedPlan: "plan"
        case .htmlRender: "html"
        case .mcpApp: "app"
        }
    }

    /// Entry ids a row shows on its own (not as a repeat inside an expanded group's body).
    static func shownIds(_ row: TimelineRow) -> [String] {
        switch row.kind {
        case .message(let m, _, _, _, _, _): [m.id.rawValue]
        case .work(let entries, false, _): entries.map(\.id)
        case .workLive(_, let entries, _, false, _, _): entries.map(\.id)
        case .contextCompaction: [row.id]
        case .event(let p, let subagents, false): (subagents ?? [p]).map(\.item.id.rawValue)
        case .proposedPlan, .htmlRender, .mcpApp: [row.id]
        default: []
        }
    }

    /// Rows of one derive: unique ids, every entry shown at most once, live rows only while the
    /// thread works, and expansion flags that match the UI state.
    static func rows(_ rows: [TimelineRow], input: TimelineRowsInput) -> [String] {
        var problems: [String] = []
        var ids = Set<String>()
        for row in rows where !ids.insert(row.id).inserted { problems.append("row id \(row.id) repeats") }
        var shown: [String: Int] = [:]
        for row in rows { for id in shownIds(row) { shown[id, default: 0] += 1 } }
        for (id, count) in shown where count > 1 { problems.append("entry \(id) shown \(count) times") }
        var details: [String: Int] = [:]
        for row in rows {
            if case .work(_, true, _) = row.kind { details[row.id, default: 0] += 1 }
        }
        let working = rows.filter { if case .working = $0.kind { true } else { false } }.count
        let live = rows.filter { row in
            switch row.kind {
            case .thinking, .working: true
            case .workLive(_, _, _, _, let active, _): active
            default: false
            }
        }
        if input.isWorking {
            if working != 1 { problems.append("\(working) working rows while working") }
        } else if !live.isEmpty {
            problems.append("live rows outlive the run: \(live.map(\.id))")
        }
        for (i, row) in rows.enumerated() {
            var group: (String, Bool)?
            switch row.kind {
            case .workLive(_, _, let id, let expanded, _, _): group = (id, expanded)
            case .workToggle(let t): group = (t.groupId, t.expanded)
            case .thinking(let id?, let expanded?, _): group = (id, expanded)
            case .turnFold(let run, _, let expanded):
                if expanded != input.expandedRunIds.contains(run) { problems.append("turn fold \(run.rawValue) expansion lost") }
            case .attemptFold(_, let attempt, _, let expanded):
                if expanded != input.expandedAttemptIds.contains(attempt) { problems.append("attempt fold \(attempt.rawValue) expansion lost") }
            default: break
            }
            guard let (id, expanded) = group else { continue }
            if expanded != input.expandedWorkGroupIds.contains(id) { problems.append("group \(id) expansion lost") }
            if expanded, rows.indices.contains(i + 1) ? rows[i + 1].id != "\(id):details" : true {
                problems.append("expanded group \(id) has no body after it")
            }
        }
        return problems
    }

    /// With every fold and group open, each message and event shows exactly once and each settled,
    /// visible work entry shows exactly once, in a row or a group body.
    static func everythingOnce(_ base: TimelineRowsInput, projection: ThreadProjection) -> [String] {
        var input = base
        input.expandedRunIds = Set(projection.runs.map(\.id))
        input.expandedAttemptIds = Set(projection.attempts.map(\.id))
        // Group ids depend on the rows; open every group the closed pass shows, then derive again.
        // Inherited rows fold under runs of the parent thread, which only the rows name.
        var groups = Set<String>()
        for _ in 0..<4 {
            let before = (input.expandedWorkGroupIds, input.expandedRunIds)
            input.expandedWorkGroupIds = groups
            for row in TimelineRows.derive(input) {
                switch row.kind {
                case .workLive(_, _, let id, _, _, _), .thinking(let id?, _, _): groups.insert(id)
                case .workToggle(let t): groups.insert(t.groupId)
                case .turnFold(let run, _, _): input.expandedRunIds.insert(run)
                default: break
                }
            }
            if groups == before.0, input.expandedRunIds == before.1 { break }
        }
        input.expandedWorkGroupIds = groups
        let rows = TimelineRows.derive(input)
        var problems = Self.rows(rows, input: input)
        var count: [String: Int] = [:]
        for row in rows {
            switch row.kind {
            case .work(let entries, true, _): for e in entries { count[e.id, default: 0] += 1 }
            case .workLive(_, let entries, _, false, _, _), .work(let entries, false, _): for e in entries { count[e.id, default: 0] += 1 }
            case .message(let m, _, _, _, _, _): count[m.id.rawValue, default: 0] += 1
            case .event(let p, let subagents, false): for s in subagents ?? [p] { count[s.item.id.rawValue, default: 0] += 1 }
            case .contextCompaction, .proposedPlan, .htmlRender, .mcpApp: count[row.id, default: 0] += 1
            default: break
            }
        }
        for entry in input.entries {
            switch entry.kind {
            case .message(let m, _):
                if count[m.id.rawValue] != 1 { problems.append("message \(m.id.rawValue) shown \(count[m.id.rawValue] ?? 0) times, all open") }
            case .event(let p) where p.item.type != .runInterruptRequest:
                if count[entry.id] != 1 { problems.append("event \(entry.id) shown \(count[entry.id] ?? 0) times, all open") }
            case .work(let w) where w.toolLifecycleStatus != .inProgress && WorkLog.isVisibleInGroup(w):
                if count[entry.id] != 1 { problems.append("work \(entry.id) shown \(count[entry.id] ?? 0) times, all open") }
            default: break
            }
        }
        return problems
    }

    /// The change a pipeline result names, applied to the rows shown before, must give its rows.
    static func change(_ change: TimelineChange, old: [TimelineRow], new: [TimelineRow]) -> [String] {
        switch change {
        case .all, .thread:
            return []
        case .rows(let changed):
            guard old.count == new.count else { return [".rows with \(old.count) old and \(new.count) new rows"] }
            let set = Set(changed)
            let missed = new.indices.filter { !set.contains($0) && old[$0] != new[$0] }
            return missed.isEmpty ? [] : [".rows missed changed rows \(missed.map { new[$0].id })"]
        case .tail(let first):
            guard first <= old.count, first <= new.count else { return [".tail(\(first)) past the rows"] }
            let missed = (0..<first).filter { old[$0] != new[$0] }
            return missed.isEmpty ? [] : [".tail(\(first)) kept changed rows \(missed.map { new[$0].id })"]
        case .head(let replaced, let inserted):
            guard replaced <= old.count, inserted <= new.count, old.count - replaced == new.count - inserted else {
                return [".head(\(replaced), \(inserted)) does not fit \(old.count) to \(new.count) rows"]
            }
            let missed = (0..<(old.count - replaced)).filter { old[replaced + $0] != new[inserted + $0] }
            return missed.isEmpty ? [] : [".head kept changed rows \(missed.map { new[inserted + $0].id })"]
        }
    }
}
