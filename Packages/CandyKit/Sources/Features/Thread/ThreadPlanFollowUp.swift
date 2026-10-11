import Foundation
import T3Protocol

/// proposedPlan.ts:54-77 and ChatView.logic.ts:938-952.
public enum ThreadPlanFollowUp {
    public static func submission(draft: String, markdown: String) -> (text: String, mode: InteractionMode) {
        let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? ("PLEASE IMPLEMENT THIS PLAN:\n" + markdown.trimmingCharacters(in: .whitespacesAndNewlines), .default) : (draft, .plan)
    }
    public static func activePlan(_ projection: ThreadProjection?) -> PlanArtifact? {
        guard let projection else { return nil }
        let latest = projection.runs.max { $0.ordinal < $1.ordinal }
        guard let latest, latest.status == .completed || latest.status == .interrupted || latest.status == .failed else { return nil }
        let plans = projection.plans.filter { $0.kind == "proposed_plan" }
        let candidates = plans.filter { $0.runId == latest.id }
        return (candidates.isEmpty ? plans : candidates).last.flatMap { $0.status == "active" && $0.markdown?.isEmpty == false ? $0 : nil }
    }
}
