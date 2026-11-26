import Foundation
import T3Protocol

/// A step of a run told as part of its story (`WorkflowBeat`, 5258 client-runtime workflows.ts:541-562).
public struct WorkflowBeat: Hashable, Sendable {
    /// A step's kind, or `run` for an invoked run told by the wait for it.
    public var kind: String
    public var name: String
    public var status: String
    public var attempts: Int
    /// A failure's reason, or when a sleep wakes.
    public var detail: String?
    public var result: JSONValue?
    public var said: String?
    public var ahead: Int?
    public var startMs: Double
    /// When it ended, or now while it is under way.
    public var endMs: Double
    public var thread: WorkflowThreadTarget?
    public var childRun: WorkflowRun?
    /// Another beat was under way at the same time.
    public var parallel: Bool
}

/// An agent's thread, in the run's environment when `environmentId` is nil (`WorkflowThreadTarget`).
public struct WorkflowThreadTarget: Hashable, Sendable {
    public var threadId: String
    public var environmentId: String?
    public init(threadId: String, environmentId: String?) { self.threadId = threadId; self.environmentId = environmentId }
}

/// One row of the timeline as it is read (`WorkflowFeedRow`, :718-723): a beat, the quick steps between two beats,
/// or beats under way at the same time.
public enum WorkflowFeedRow: Hashable, Sendable {
    case beat(WorkflowBeat)
    case quick(steps: [WorkflowStep], startMs: Double, endMs: Double)
    case together([WorkflowBeat])

    /// The key the feed's focus names it by (WorkflowRunFeed.tsx:367-372).
    public var key: String {
        switch self {
        case .beat(let b): "step:\(b.name)"
        case .quick(let steps, _, _): "quick:\(steps.first?.name ?? "")"
        case .together(let beats): "step:\(beats.first?.name ?? "")"
        }
    }
}

public enum WorkflowTimeline {
    /// `QUICK_STEP_MS` (:539): a step this short is bookkeeping between the parts of a run that take time.
    static let quickStepMs: Double = 1000

    public static func ms(_ iso: String) -> Double { T3Timestamp.parseEpochMs(iso).map(Double.init) ?? 0 }

    /// `buildWorkflowTimeline` (:584-668): beats in order, quick steps between two beats folded into one row, and an
    /// invoked run in place of the two steps that started and awaited it.
    public static func rows(run: WorkflowRun, steps: [WorkflowStep], children: [WorkflowRun], nowMs: Double) -> [WorkflowFeedRow] {
        var childByStep: [String: WorkflowRun] = [:]
        for child in children where child.parentRunId == run.runId {
            if let step = child.parentStep { childByStep[step] = child }
        }
        let startMs = ms(run.startedAt)
        // A caller's clock can be a minute old. Now is never before anything the run has done.
        let now = ([nowMs, startMs] + steps.map { ms($0.endedAt ?? $0.startedAt) }).max()!
        var rows: [WorkflowFeedRow] = []
        var quick: [WorkflowStep] = []
        func flush() {
            guard let first = quick.first, let last = quick.last else { return }
            rows.append(.quick(steps: quick, startMs: ms(first.startedAt), endMs: ms(last.endedAt ?? last.startedAt)))
            quick = []
        }
        for step in steps {
            if step.kind == "step", step.name.hasSuffix("/start"), childByStep[String(step.name.dropLast(6))] != nil { continue }
            let stepStart = ms(step.startedAt)
            let stepEnd = step.endedAt.map(ms) ?? now
            let childRun = step.kind == "wait" ? childByStep[step.name] : nil
            let isBeat = (step.kind != "step" && step.kind != "queue") || step.status != "completed" || step.attempts > 1
                || stepEnd - stepStart >= quickStepMs
            guard isBeat else { quick.append(step); continue }
            flush()
            rows.append(.beat(WorkflowBeat(
                kind: childRun == nil ? step.kind : "run", name: step.name, status: step.status, attempts: Int(step.attempts),
                detail: step.detail, result: step.result, said: step.said, ahead: step.ahead.map { Int($0) },
                startMs: stepStart, endMs: max(stepStart, stepEnd),
                thread: step.threadId.map { WorkflowThreadTarget(threadId: $0, environmentId: step.environmentId) },
                childRun: childRun, parallel: false)))
        }
        flush()
        let beats = rows.compactMap { if case .beat(let b) = $0 { return b }; return nil }
        func overlaps(_ l: WorkflowBeat, _ r: WorkflowBeat) -> Bool { l != r && l.startMs < openEnd(r) && r.startMs < openEnd(l) }
        return rows.map { row in
            guard case .beat(var b) = row else { return row }
            b.parallel = beats.contains { overlaps(b, $0) }
            return .beat(b)
        }
    }

    /// `openEnd` (:671-673): one still under way never stops overlapping.
    static func openEnd(_ b: WorkflowBeat) -> Double { b.status == "running" ? .infinity : b.endMs }

    /// `buildWorkflowFeed` (:729-756): beats that overlapped become one row.
    public static func feed(_ rows: [WorkflowFeedRow]) -> [WorkflowFeedRow] {
        var out: [WorkflowFeedRow] = []
        var together: [WorkflowBeat] = []
        var until: Double = 0
        func flush() {
            if together.count == 1 { out.append(.beat(together[0])) } else if together.count > 1 { out.append(.together(together)) }
            together = []
        }
        for row in rows {
            guard case .beat(let b) = row else { flush(); out.append(row); continue }
            if !together.isEmpty, b.parallel, b.startMs < until {
                together.append(b)
                until = max(until, openEnd(b))
                continue
            }
            flush()
            together = [b]
            until = openEnd(b)
        }
        flush()
        return out
    }

    /// `beatsOf` (:759-760): every beat, in order.
    public static func beats(_ rows: [WorkflowFeedRow]) -> [WorkflowBeat] {
        rows.flatMap { row -> [WorkflowBeat] in
            switch row {
            case .beat(let b): [b]
            case .together(let bs): bs
            case .quick: []
            }
        }
    }

    /// `workflowPausedBeat` (:765-781): the last failed beat, unless the run went on after it.
    public static func pausedBeat(_ rows: [WorkflowFeedRow], status: String) -> WorkflowBeat? {
        guard status == "paused", let failed = beats(rows).last(where: { $0.status == "failed" }) else { return nil }
        let wentOn = rows.contains { row in
            switch row {
            case .together(let bs): bs.contains { $0 != failed && $0.startMs >= failed.endMs }
            case .beat(let b): b != failed && b.startMs >= failed.endMs
            case .quick(_, let start, _): start >= failed.endMs
            }
        }
        return wentOn ? nil : failed
    }

    /// `workflowFlowFocus` (:784-807): what waits on a person, then where it failed, then how it ended, then what
    /// is under way.
    public static func focus(_ rows: [WorkflowFeedRow], status: String, ended: Bool, questions: [String]) -> String? {
        let all = beats(rows)
        if let asked = questions.first {
            let at = all.first { $0.kind == "ask" && $0.status == "running" && questions.contains($0.name) }
            return at.map { "step:\($0.name)" } ?? "question:\(asked)"
        }
        if status == "paused" { return pausedBeat(rows, status: status).map { "step:\($0.name)" } ?? "pause" }
        if ended { return "end" }
        return (all.last { $0.status == "running" } ?? all.last).map { "step:\($0.name)" }
    }

    // MARK: Words

    /// `workflowStepTime` (:946-952): 0.3s, 9.7s, 12s, then minutes.
    public static func stepTime(_ ms: Double) -> String {
        if ms < 9950, ms.truncatingRemainder(dividingBy: 1000) != 0 { return String(format: "%.1fs", max(ms, 100) / 1000) }
        let seconds = (ms / 1000).rounded(.toNearestOrAwayFromZero)
        if seconds < 60 { return "\(Int(seconds))s" }
        return formatDuration(ms)
    }

    /// `wholeSeconds` (WorkflowRunFeed.tsx:116): a time still counting is told to the second.
    public static func wholeSeconds(_ ms: Double) -> Double { max(1000, (ms / 1000).rounded(.toNearestOrAwayFromZero) * 1000) }

    /// `elapsedOf` (:117-118).
    public static func elapsed(_ b: WorkflowBeat) -> Double { b.status == "running" ? wholeSeconds(b.endMs - b.startMs) : b.endMs - b.startMs }

    /// `nthTry` (:191-196).
    public static func nthTry(_ n: Int) -> String {
        switch n { case 1: "1st try"; case 2: "2nd try"; case 3: "3rd try"; default: "\(n)th try" }
    }

    /// `workflowOneLine` (:957-970): the first sentence of a reply as plain words.
    public static func oneLine(_ text: String) -> String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") && !$0.hasPrefix("|") } ?? ""
        var line = first.replacingOccurrences(of: #"^([-*>]|\d+\.)\s+"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"(\*\*|__|\*|_)(\S(?:.*?\S)?)\1"#, with: "$2", options: .regularExpression)
        guard let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) else { return line }
        return String(line[..<line.index(after: end.lowerBound)])
    }

    /// `workflowAgentSummary` (:839-871): an agent's words and the short facts of its result.
    public static func agentSummary(result: JSONValue?, said: String?) -> (said: String?, facts: [(label: String, value: String)]) {
        let kept = said?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if case .string(let s)? = result {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return (kept.isEmpty ? (t.isEmpty ? nil : t) : kept, [])
        }
        guard case .object(let o)? = result else { return (kept.isEmpty ? nil : kept, []) }
        // ponytail: key order, as resultLines, since JSONValue drops the wire order.
        let entries = o.keys.sorted().map { ($0, o[$0]!) }
        let prose: String? = kept.isEmpty ? entries.compactMap { e -> String? in
            if case .string(let s) = e.1, s.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80 { return s }
            return nil
        }.max { $0.count < $1.count } : nil
        let facts = entries.compactMap { e in factValue(e.1).map { (words(e.0), $0) } }.prefix(6)
        return (kept.isEmpty ? prose?.trimmingCharacters(in: .whitespacesAndNewlines) : kept, Array(facts))
    }

    static func words(_ key: String) -> String {
        key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression).lowercased()
    }

    static func factValue(_ v: JSONValue) -> String? {
        switch v {
        case .bool(let b): return b ? "yes" : "no"
        case .number: return WorkflowRuns.jsString(v)
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && t.count <= 48 && !t.contains("\n") ? t : nil
        case .array(let a) where !a.isEmpty && a.count <= 4:
            let parts = a.map(factValue)
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            let joined = parts.map { $0! }.joined(separator: ", ")
            return joined.count <= 48 ? joined : nil
        default: return nil
        }
    }

    /// `workflowSaidStart` (:877-899): the start of a long reply, cut where a paragraph ends; nil when all fits.
    public static func saidStart(_ said: String, limit: Int) -> String? {
        let units = Array(said.utf16)
        guard units.count > limit else { return nil }
        let paragraphs = said.components(separatedBy: try! NSRegularExpression(pattern: "\n{2,}"))
        var kept = paragraphs[0]
        for p in paragraphs.dropFirst() {
            if kept.utf16.count + p.utf16.count + 2 > limit { break }
            kept += "\n\n" + p
        }
        if kept.utf16.count > limit * 2 {
            let k = Array(kept.utf16)
            let space = k[..<min(k.count, limit + 1)].lastIndex(of: 0x20)
            let before = k[limit - 1]
            let end = space.flatMap { $0 > 0 ? $0 : nil } ?? (before >= 0xD800 && before <= 0xDBFF ? limit - 1 : limit)
            kept = (String(utf16CodeUnits: Array(k[..<end]), count: end)) + "…"
        }
        return kept == said ? nil : kept
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        var out: [String] = []
        var last = startIndex
        for m in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
            let r = Range(m.range, in: self)!
            out.append(String(self[last..<r.lowerBound]))
            last = r.upperBound
        }
        out.append(String(self[last...]))
        return out
    }
}
