import Foundation
import T3Protocol
import T3Store

/// What the Workflows page shows for one environment's list (5258 components/workflows/WorkflowRunsView.tsx:104-336):
/// the tab, the filters, the rows and the run told beside them.
public struct WorkflowsListing: Equatable, Sendable {
    public var tab: WorkflowListTab
    /// Registered and seen workflows, for the workflow select (shown when there are two or more).
    public var workflows: [WorkflowSection]
    public var section: WorkflowSection?
    /// The Needs you tab's kinds (WorkflowRunsView.tsx:243-250); empty hides the select.
    public var kinds: [WorkflowQuestionKind]
    /// `EVERY_KIND`, or the kind the list is narrowed to.
    public var kind: String
    public var rows: [WorkflowRunNode]
    /// The row drawn as current: the shown run, or the run it is part of.
    public var currentRunId: String?
    /// The run told beside the list; nil with `notHere` when the address names a run the list lacks.
    public var shown: WorkflowRunNode?
    public var parent: WorkflowRun?
    public var notHere: Bool
    public var skipped: Int
    public var openedSkipped: Bool
    /// The text of an empty list.
    public var nothing: String
}

public enum WorkflowsPageLogic {
    /// WorkflowRunsView.tsx:182-336, with `pickedTab`, the workflow filter, the stored kind and Show skipped.
    public static func listing(_ snapshot: WorkflowRunsSnapshot, selectedRunId: String?, pickedTab: WorkflowListTab?,
                               workflow: String, pickedKind: String, showSkipped: Bool) -> WorkflowsListing {
        // A skipped run opened by its link is shown all the same (:182-185).
        let openedSkipped = snapshot.runs.contains { $0.runId == selectedRunId && $0.status == "skipped" }
        let visible = WorkflowRuns.listed(snapshot.runs, showSkipped: showSkipped || openedSkipped)
        let groups = WorkflowRuns.group(snapshot.workflows, visible.runs, snapshot.questions)
        let lists = WorkflowRuns.lists(groups)
        let all = WorkflowRuns.all(groups)
        let section = groups.workflows.first { $0.name == workflow }
        // A run another invoked is listed as the one it is part of (:191-195).
        func listedFor(_ node: WorkflowRunNode?) -> String? {
            guard let node else { return nil }
            guard let parent = all.first(where: { $0.run.runId == node.run.parentRunId }) else { return node.run.runId }
            return listedFor(parent)
        }
        let selected = selectedRunId.flatMap { id in all.first { $0.run.runId == id } }
        let opening = WorkflowRuns.defaultTab(groups)
        func holds(_ t: WorkflowListTab) -> Bool { (lists[t] ?? []).contains { $0.run.runId == listedFor(selected) } }
        let tab = pickedTab ?? (selectedRunId == nil || holds(opening) ? opening : holds(.running) ? .running : .all)
        let ofWorkflow = (lists[tab] ?? []).filter { section == nil || WorkflowRuns.involves($0, section!.name) }
        // The pick stays when its last question is answered (:212-214).
        let kind = tab == .needsYou ? pickedKind : WorkflowRuns.everyKind
        let kinds = tab == .needsYou
            ? WorkflowRuns.questionKinds([(snapshot.workflows, ofWorkflow)], picked: kind == WorkflowRuns.everyKind ? nil : kind) : []
        let openRunId = listedFor(selected)
        let rows = kind == WorkflowRuns.everyKind ? ofWorkflow
            : ofWorkflow.filter { WorkflowRuns.asksKind(snapshot.workflows, $0, kind) || $0.run.runId == openRunId }
        let shown: WorkflowRunNode? = selectedRunId != nil ? selected
            : kind == WorkflowRuns.everyKind ? all.first { $0.run.runId == WorkflowRuns.defaultRunId(groups) }
            : WorkflowRuns.askingKind(snapshot.workflows, rows, kind)
        let nothing = section?.neverRan == true ? "Has not run yet."
            : kind == WorkflowRuns.everyKind ? tab.nothing : "No questions of this kind wait on you."
        return .init(tab: tab, workflows: groups.workflows, section: section, kinds: kinds, kind: kind, rows: rows,
                     currentRunId: listedFor(shown), shown: shown,
                     parent: shown.flatMap { s in all.first { $0.run.runId == s.run.parentRunId }?.run },
                     notHere: selectedRunId != nil && selected == nil, skipped: visible.skipped, openedSkipped: openedSkipped, nothing: nothing)
    }

    /// `kindLabel` (WorkflowRunsView.tsx:251-252).
    public static func kindLabel(_ k: WorkflowQuestionKind) -> String { k.label ?? "Other" }

    /// The kinds line under the select with All kinds picked (:357-361).
    public static func kindsLine(_ kinds: [WorkflowQuestionKind]) -> String {
        kinds.map { "\(kindLabel($0)) \($0.count)" }.joined(separator: " · ")
    }

    /// `pickKind` (:270-280): the run the address should move to, or nil to keep it.
    public static func runAfterPicking(_ snapshot: WorkflowRunsSnapshot, kind: String, selected: WorkflowRunNode?, ofWorkflow: [WorkflowRunNode]) -> String?? {
        guard let selected, kind != WorkflowRuns.everyKind else { return .none }
        if WorkflowRuns.askingKind(snapshot.workflows, [selected], kind)?.run.runId == selected.run.runId { return .none }
        return .some(WorkflowRuns.askingKind(snapshot.workflows, ofWorkflow, kind)?.run.runId)
    }

    /// `openListed` (:281-289): a row listed for a question a run it invoked asks opens on that run.
    public static func runToOpen(_ snapshot: WorkflowRunsSnapshot, row: WorkflowRunNode, kind: String) -> String {
        guard kind != WorkflowRuns.everyKind else { return row.run.runId }
        return WorkflowRuns.askingKind(snapshot.workflows, [row], kind)?.run.runId ?? row.run.runId
    }

    /// The meta line under a run's title (WorkflowRunFeed.tsx:487-520): "started 5m ago · took 2m 3s".
    public static func metaLine(_ run: WorkflowRun, nowMs: Int64) -> [String] {
        var parts = ["started \(TimestampFormat.formatRelativeTimeLabel(run.startedAt, nowMs: nowMs))"]
        let start = ms(run.startedAt) ?? Double(nowMs)
        if run.status != "paused" {
            if let end = run.endedAt.flatMap(ms) { parts.append("took \(formatDuration(max(0, end - start)))") }
            else { parts.append("\(formatDuration(max(1000, ((Double(nowMs) - start) / 1000).rounded() * 1000))) so far") }
        }
        if run.retired { parts.append("its version is no longer registered") }
        return parts
    }

    static func ms(_ iso: String) -> Double? { T3Timestamp.parseEpochMs(iso).map(Double.init) }

    /// A step's state as its row says it: the kind's verb and how long it took.
    public static func stepLine(_ step: WorkflowStep, nowMs: Int64) -> String {
        let start = ms(step.startedAt) ?? Double(nowMs)
        let end = step.endedAt.flatMap(ms) ?? Double(nowMs)
        var parts: [String] = []
        switch (step.kind, step.status) {
        case ("queue", "running"):
            // `queuedText` (WorkflowRunFeed.tsx:198-205), pools from 462596a0f7 #42518.
            let ahead = Int(step.ahead ?? 0)
            parts.append(ahead > 0 ? "queued, \(ahead) ahead" : "queued, next in line")
        case ("sleep", "running"): parts.append("sleeping")
        case ("ask", "running"): parts.append("waiting on you")
        case (_, "failed"): parts.append(step.attempts > 1 ? "failed after \(Int(step.attempts)) tries" : "failed")
        case (_, "running"): parts.append("running")
        default: break
        }
        parts.append(formatDuration(max(0, end - start)))
        return parts.joined(separator: " · ")
    }

    /// `workflowAnswer` (client-runtime workflows.ts:670-692): what a person answered with, and who.
    public static func answer(_ result: JSONValue?) -> (choice: String, reason: String?, answeredBy: String?, answeredBySession: String?)? {
        guard case .string(let choice)? = result?["choice"] else { return nil }
        func text(_ k: String) -> String? {
            guard case .string(let s)? = result?[k], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        return (choice, text("reason"), text("answeredBy"), text("answeredBySession"))
    }

    /// `workflowWithdrawal` (:695-706), 3b5033a28c #42506.
    public static func withdrawal(_ result: JSONValue?) -> (by: String, reason: String?)? {
        guard case .string(let by)? = result?["withdrawn"]?["by"] else { return nil }
        guard case .string(let r)? = result?["withdrawn"]?["reason"], !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (by, nil) }
        return (by, r)
    }

    /// "You said {choice}." or "{who} said {choice}: {reason}" (WorkflowRunFeed.tsx:1561-1595), 7be3a767cc #42515.
    public static func saidLine(who: String?, choice: String, reason: String?) -> String {
        let lead = who.map { "\($0) said \(choice)" } ?? "You said \(choice)"
        return reason.map { "\(lead): \($0)" } ?? "\(lead)."
    }

    /// The first line of an agent's reply, as plain words (a simple `workflowOneLine`, :951-970).
    // ponytail: strips leading markdown marks only; port workflowOneLine's inline-markup rules when replies read wrong.
    public static func oneLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#>*- ")).replacingOccurrences(of: "`", with: "")
    }
}
