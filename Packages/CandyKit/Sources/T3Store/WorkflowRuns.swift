import Foundation
import T3Protocol

// The run list a person reads, ported from 5258 packages/client-runtime/src/workflows.ts (commits 69c1d53826 #38884,
// 5ac27b4007 #42008, 7be3a767cc #42515, 462596a0f7 #42518). Line numbers below are in that file.

/// One environment's live `workflows.subscribe` list (client-runtime state/server.ts:1473-1485). The app owns the
/// subscription and feeds frames here; the page reads `snapshot`. Nil until the first frame.
@MainActor
public final class WorkflowRunsStore {
    public private(set) var snapshot: WorkflowRunsSnapshot?
    public private(set) var error: String?
    /// Every change, so the page redraws.
    public var onChange: (() -> Void)?

    public init() {}

    /// A new subscription starts from the whole list the server sends first.
    public func subscribed() { snapshot = nil; error = nil }

    public func apply(_ update: WorkflowRunsUpdate) {
        snapshot = update.applied(to: snapshot)
        error = nil
        onChange?()
    }

    public func fail(_ message: String) { error = message; onChange?() }

    public func reset() { snapshot = nil; error = nil }
}

/// A run with the runs it invoked and its open questions (`WorkflowRunNode`, :103-109).
public struct WorkflowRunNode: Hashable, Sendable {
    public var run: WorkflowRun
    /// In the order they started.
    public var children: [WorkflowRunNode]
    public var questions: [WorkflowQuestion]

    public init(run: WorkflowRun, children: [WorkflowRunNode] = [], questions: [WorkflowQuestion] = []) {
        self.run = run; self.children = children; self.questions = questions
    }
}

/// One workflow and its runs that nobody has to act on (`WorkflowSection`, :112-122).
public struct WorkflowSection: Hashable, Sendable {
    public var name: String
    /// Nil for a workflow this server no longer has registered.
    public var triggers: [String]?
    public var active: [WorkflowRunNode]
    public var finished: [WorkflowRunNode]
    public var invokedOnly: Bool
    public var neverRan: Bool
}

public struct WorkflowRunGroups: Hashable, Sendable {
    public var needsYou: [WorkflowRunNode]
    public var workflows: [WorkflowSection]
}

public enum WorkflowListTab: String, CaseIterable, Sendable {
    case needsYou = "needs-you", running, all

    /// WorkflowRunsView.tsx:48-55.
    public var label: String {
        switch self { case .needsYou: "Needs you"; case .running: "Running"; case .all: "All" }
    }

    /// `NOTHING` (WorkflowRunsView.tsx:56-60).
    public var nothing: String {
        switch self { case .needsYou: "Nothing waits on you."; case .running: "Nothing is running."; case .all: "No runs yet." }
    }
}

public enum WorkflowRunTone: String, Sendable { case input, failed, working, quiet, done }

/// A choice of a question (`WorkflowQuestionChoice`, :21-27).
public struct WorkflowQuestionChoice: Hashable, Sendable {
    public var value: String
    public var description: String?
    public var requireReason: Bool
}

public struct WorkflowQuestionLink: Hashable, Sendable {
    public var label: String
    public var url: String
}

public struct WorkflowQuestionView: Hashable, Sendable {
    public var title: String
    public var choices: [WorkflowQuestionChoice]
    public var body: String?
    public var links: [WorkflowQuestionLink]
}

/// A kind of question in the Needs you filter (`WorkflowQuestionKind`, :291-298).
public struct WorkflowQuestionKind: Hashable, Sendable {
    public var kind: String
    /// Nil for Other, which the caller words.
    public var label: String?
    public var count: Int
}

public enum WorkflowRuns {
    /// `WORKFLOW_OTHER_KIND` (:288).
    public static let otherKind = ""
    /// `EVERY_KIND` (WorkflowRunsView.tsx:45): never a kind.
    public static let everyKind = "*"
    /// WorkflowRunsView.tsx:43.
    public static let guideURL = "https://github.com/pingdotgg/t3code/blob/main/docs/user/workflows.md"

    // MARK: Questions

    private static func text(_ v: JSONValue?) -> String? {
        guard case .string(let s)? = v, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func isWebURL(_ s: String) -> Bool {
        guard let scheme = URL(string: s)?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// `readWorkflowQuestion` (:58-87): parts of another shape are left out.
    public static func read(_ question: WorkflowQuestion) -> WorkflowQuestionView {
        let r = question.request
        var choices: [WorkflowQuestionChoice] = []
        if case .array(let list)? = r["choices"] {
            let details: [JSONValue] = { if case .array(let d)? = r["choiceDetails"] { return d }; return [] }()
            for case .string(let value) in list {
                let detail = details.first { $0["value"] == .string(value) }
                choices.append(.init(value: value, description: text(detail?["description"]),
                                     requireReason: detail?["requireReason"] == .bool(true)))
            }
        }
        var links: [WorkflowQuestionLink] = []
        if case .array(let list)? = r["links"] {
            for link in list {
                if let label = text(link["label"]), case .string(let url)? = link["url"], isWebURL(url) { links.append(.init(label: label, url: url)) }
            }
        }
        return .init(title: text(r["title"]) ?? question.name, choices: choices, body: text(r["data"]?["body"]), links: links)
    }

    /// `workflowRunRefreshKey` (:93-99): an ended run's detail is read again only when it changes; one under way on
    /// any change of the list, since steps do not move `updatedAt`. Nil means "any change".
    public static func refreshKey(_ snapshot: WorkflowRunsSnapshot?, runId: String) -> String? {
        guard let run = snapshot?.runs.first(where: { $0.runId == runId }), run.endedAt != nil else { return nil }
        return run.updatedAt
    }

    // MARK: Grouping

    private static func needsPerson(_ node: WorkflowRunNode) -> Bool {
        !node.questions.isEmpty || node.run.status == "paused" || node.children.contains(where: needsPerson)
    }

    /// `listedWorkflowRuns` (:140-148): top-level skipped runs leave unless asked for.
    public static func listed(_ runs: [WorkflowRun], showSkipped: Bool) -> (runs: [WorkflowRun], skipped: Int) {
        func hidden(_ r: WorkflowRun) -> Bool { r.status == "skipped" && r.parentRunId == nil }
        return (showSkipped ? runs : runs.filter { !hidden($0) }, runs.filter(hidden).count)
    }

    /// `groupWorkflowRuns` (:150-218). `runs` is newest first and that order is kept.
    public static func group(_ workflows: [WorkflowSummary], _ runs: [WorkflowRun], _ questions: [WorkflowQuestion]) -> WorkflowRunGroups {
        let ids = Set(runs.map(\.runId))
        var childrenOf: [String: [WorkflowRun]] = [:]
        var roots: [WorkflowRun] = []
        for run in runs {
            if let parent = run.parentRunId, ids.contains(parent) { childrenOf[parent, default: []].append(run) } else { roots.append(run) }
        }
        func node(_ run: WorkflowRun) -> WorkflowRunNode {
            let kids = (childrenOf[run.runId] ?? []).enumerated()
                .sorted { $0.element.startedAt == $1.element.startedAt ? $0.offset < $1.offset : $0.element.startedAt < $1.element.startedAt }
                .map { node($0.element) }
            return .init(run: run, children: kids, questions: questions.filter { $0.runId == run.runId })
        }
        var needsYou: [WorkflowRunNode] = []
        var sections: [String: (active: [WorkflowRunNode], finished: [WorkflowRunNode])] = [:]
        var sectionOrder: [String] = []
        for root in roots.map(node) {
            if needsPerson(root) { needsYou.append(root); continue }
            let name = root.run.workflow
            if sections[name] == nil { sections[name] = ([], []); sectionOrder.append(name) }
            if root.run.endedAt == nil { sections[name]!.active.append(root) } else { sections[name]!.finished.append(root) }
        }
        let registered = Dictionary(workflows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let hasRuns = Set(runs.map(\.workflow))
        let hasRootRuns = Set(roots.map(\.workflow))
        var names: [String] = []
        var seen = Set<String>()
        for n in sectionOrder + workflows.map(\.name) + runs.map(\.workflow) where seen.insert(n).inserted { names.append(n) }
        func rank(_ n: String) -> Int {
            guard let s = sections[n] else { return 2 }
            return !s.active.isEmpty ? 0 : !s.finished.isEmpty ? 1 : 2
        }
        let list = names.map { n in
            WorkflowSection(name: n, triggers: registered[n]?.triggers, active: sections[n]?.active ?? [], finished: sections[n]?.finished ?? [],
                            invokedOnly: hasRuns.contains(n) && !hasRootRuns.contains(n), neverRan: !hasRuns.contains(n))
        }.sorted { rank($0.name) != rank($1.name) ? rank($0.name) < rank($1.name) : $0.name.localizedCompare($1.name) == .orderedAscending }
        return .init(needsYou: needsYou, workflows: list)
    }

    /// `flattenWorkflowRunNodes` (:221-225): parents before the runs they invoked.
    public static func flatten(_ nodes: [WorkflowRunNode]) -> [WorkflowRunNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    /// `allWorkflowRunNodes` (:228-233).
    public static func all(_ g: WorkflowRunGroups) -> [WorkflowRunNode] {
        flatten(g.needsYou + g.workflows.flatMap { $0.active + $0.finished })
    }

    /// `defaultWorkflowRunId` (:236-250).
    public static func defaultRunId(_ g: WorkflowRunGroups) -> String? {
        if let waiting = flatten(g.needsYou).first(where: { !$0.questions.isEmpty || $0.run.status == "paused" }) { return waiting.run.runId }
        if let active = g.workflows.first(where: { !$0.active.isEmpty })?.active.first { return active.run.runId }
        return g.workflows.flatMap(\.finished).max { $0.run.updatedAt < $1.run.updatedAt }?.run.runId
    }

    /// `workflowTriggerLine` (:253-262).
    public static func triggerLine(_ s: WorkflowSection) -> String {
        guard let triggers = s.triggers else { return "No longer registered on this server" }
        if s.invokedOnly { return "Runs as part of other workflows" }
        return triggers.isEmpty ? "Started by hand" : "Starts on \(triggers.joined(separator: ", "))"
    }

    /// `workflowRunLists` (:270-282): newest change first.
    public static func lists(_ g: WorkflowRunGroups) -> [WorkflowListTab: [WorkflowRunNode]] {
        func byChange(_ n: [WorkflowRunNode]) -> [WorkflowRunNode] {
            n.enumerated().sorted { $0.element.run.updatedAt == $1.element.run.updatedAt ? $0.offset < $1.offset : $0.element.run.updatedAt > $1.element.run.updatedAt }.map(\.element)
        }
        let running = g.workflows.flatMap(\.active), finished = g.workflows.flatMap(\.finished)
        return [.needsYou: byChange(g.needsYou), .running: byChange(running), .all: byChange(g.needsYou) + byChange(running) + byChange(finished)]
    }

    /// `workflowRunInvolves` (:285-290).
    public static func involves(_ node: WorkflowRunNode, _ workflow: String) -> Bool {
        node.run.workflow == workflow || node.children.contains { involves($0, workflow) }
    }

    /// `defaultWorkflowListTab` (:385-389).
    public static func defaultTab(_ g: WorkflowRunGroups) -> WorkflowListTab {
        if !g.needsYou.isEmpty { return .needsYou }
        return g.workflows.contains { !$0.active.isEmpty } ? .running : .all
    }

    // MARK: Question kinds

    /// `workflowListedKind` (:305-315): a kind the run's workflow does not declare is Other.
    static func listedKind(_ workflows: [WorkflowSummary], _ node: WorkflowRunNode, _ q: WorkflowQuestion) -> String {
        let declared = workflows.first { $0.name == node.run.workflow }?.asks ?? []
        if let k = q.kind, declared.contains(where: { $0.kind == k }) { return k }
        return otherKind
    }

    /// `workflowRunAskingKind` (:318-329).
    public static func askingKind(_ workflows: [WorkflowSummary], _ nodes: [WorkflowRunNode], _ kind: String) -> WorkflowRunNode? {
        flatten(nodes).first { n in n.questions.contains { listedKind(workflows, n, $0) == kind } }
    }

    /// `workflowRunAsksKind` (:375-381).
    public static func asksKind(_ workflows: [WorkflowSummary], _ node: WorkflowRunNode, _ kind: String) -> Bool {
        askingKind(workflows, [node], kind) != nil
    }

    /// `workflowQuestionKinds` (:337-372): declared kinds in declared order, then Other. `picked` stays at zero.
    public static func questionKinds(_ sources: [(workflows: [WorkflowSummary], nodes: [WorkflowRunNode])], picked: String? = nil) -> [WorkflowQuestionKind] {
        var counts: [String: Int] = [:]
        var countOrder: [String] = []
        var labels: [String: String] = [:]
        var labelOrder: [String] = []
        func bump(_ k: String, by n: Int) { if counts[k] == nil { countOrder.append(k) }; counts[k, default: 0] += n }
        for source in sources {
            for node in flatten(source.nodes) { for q in node.questions { bump(listedKind(source.workflows, node, q), by: 1) } }
            for w in source.workflows { for ask in w.asks ?? [] where labels[ask.kind] == nil { labels[ask.kind] = ask.label; labelOrder.append(ask.kind) } }
        }
        if let picked, counts[picked] == nil { bump(picked, by: 0) }
        let other = counts.removeValue(forKey: otherKind)
        countOrder.removeAll { $0 == otherKind }
        if counts.isEmpty && picked == nil { return [] }
        var order: [String] = []
        var seen = Set<String>()
        for k in labelOrder + countOrder where seen.insert(k).inserted { order.append(k) }
        var out = order.compactMap { k in counts[k].map { WorkflowQuestionKind(kind: k, label: labels[k] ?? k, count: $0) } }
        if let other { out.append(.init(kind: otherKind, label: nil, count: other)) }
        return out
    }

    // MARK: Words

    /// `workflowChip` (:393-404): two letters and one of five tones, the same every time.
    public static func chip(_ name: String) -> (letters: String, tone: Int) {
        func word(_ s: Unicode.Scalar) -> Bool {
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: true
            default: false
            }
        }
        var parts: [[Unicode.Scalar]] = [[]]
        for s in name.unicodeScalars { if word(s) { parts[parts.count - 1].append(s) } else if !parts[parts.count - 1].isEmpty { parts.append([]) } }
        parts.removeAll { $0.isEmpty }
        let picked: [Unicode.Scalar] = parts.count > 1 ? [parts[0][0], parts[1][0]] : Array((parts.first ?? Array(name.unicodeScalars)).prefix(2))
        var hash = 0
        for s in name.unicodeScalars { hash = (hash * 31 + Int(s.value)) % 9973 }
        var letters = String.UnicodeScalarView()
        letters.append(contentsOf: picked)
        return (String(letters).uppercased(), hash % 5)
    }

    /// `workflowRunState` (:409-468): the one word the thread list would use.
    public static func state(_ node: WorkflowRunNode) -> (word: String, tone: WorkflowRunTone) {
        let run = node.run
        if !node.questions.isEmpty { return ("Needs you", .input) }
        switch run.status {
        case "paused": return ("Paused", .failed)
        case "running": return ("Working", .working)
        case "waiting":
            let d = run.detail ?? ""
            if d.hasPrefix("agent ") { return ("Working", .working) }
            if d.hasPrefix("sleep ") { return ("Sleeping", .quiet) }
            if d.hasPrefix("queue ") { return ("Queued", .quiet) }
            if node.children.contains(where: needsPerson) { return ("Needs you", .input) }
            return ("Waiting", .quiet)
        case "completed": return ("Done", .done)
        case "stopped": return ("Stopped", .quiet)
        case "skipped": return ("Skipped", .quiet)
        case "cancelled": return ("Cancelled", .quiet)
        default: return (run.status.capitalized, .quiet)
        }
    }

    private static func firstLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// `workflowRunNow` (:473-527): what a run is at, as the line under its title.
    public static func now(_ node: WorkflowRunNode) -> String {
        let run = node.run
        let detail = run.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let asked = node.questions.first {
            let more = node.questions.count - 1
            let q = read(asked).title
            return more > 0 ? "Asks: \(q) and \(more) more" : "Asks: \(q)"
        }
        let below = flatten(node.children)
        let holding = below.first { !$0.questions.isEmpty || $0.run.status == "paused" }
        switch run.status {
        case "paused": return detail.isEmpty ? "A step failed" : firstLine(detail)
        case "running": return "Running its own steps"
        case "waiting":
            if let holding { return "\(holding.run.title): \(now(holding))" }
            if detail.hasPrefix("agent ") { return "\(detail.dropFirst(6)) is working" }
            if detail.hasPrefix("sleep ") { return "Sleeping at \(detail.dropFirst(6))" }
            if detail.hasPrefix("queue ") { return "Queued for \(detail.dropFirst(6))" }
            let open = below.filter { $0.run.endedAt == nil }
            if !open.isEmpty { return open.count == 1 ? "Runs \(open[0].run.title)" : "\(open.count) runs under way" }
            return detail.isEmpty ? "Waiting" : "Waiting for \(detail)"
        case "completed":
            guard let line = resultLines(run.result).first else { return "Finished" }
            return firstLine(line.label.map { "\($0): \(line.value)" } ?? line.value)
        default: return detail.isEmpty ? "Ended early" : firstLine(detail)
        }
    }

    /// `workflowResultLines` (:530-541): a sentence, or the fields of an object.
    // ponytail: object fields in key order, since JSONValue drops the wire order; keep order in JSONValue if a
    // multi-field result's first line reads wrong.
    public static func resultLines(_ result: JSONValue?) -> [(label: String?, value: String)] {
        switch result {
        case nil, .null?: return []
        case .string(let s)?: return [(nil, s)]
        case .object(let o)?: return o.keys.sorted().map { k in (k, o[k]!.stringValue ?? jsString(o[k]!)) }
        case let v?: return [(nil, jsString(v))]
        }
    }

    /// `JSON.stringify` for a JSONValue, numbers as JavaScript prints them.
    public static func jsString(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s):
            let data = (try? JSONEncoder().encode(s)) ?? Data()
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        case .array(let a): return "[" + a.map(jsString).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { jsString(.string($0)) + ":" + jsString(o[$0]!) }.joined(separator: ",") + "}"
        }
    }
}
