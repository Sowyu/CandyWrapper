import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// `ModelSwitchRow` (V2LifecycleRow.tsx:640-662 at 4928) and `resolveModelSwitchChange` (client-runtime handoff.ts):
/// only what changed shows, and a switch that changed nothing shows no row.
@MainActor
struct ModelSwitchRowTests {
    static func item(_ modelSwitch: String?) -> ProjectedTurnItem {
        var json = #"{"id":"u1","threadId":"t","type":"user_message","runId":null,"nodeId":null,"providerTurnId":null,"parentItemId":null,"ordinal":0,"status":"completed","title":null,"startedAt":null,"completedAt":null,"updatedAt":"2026-01-01T00:00:00Z","text":"hi""#
        if let modelSwitch { json += #","modelSwitch":"# + modelSwitch }
        json += "}"
        return ProjectedTurnItem(local: try! JSONDecoder().decode(TurnItem.self, from: Data(json.utf8)))
    }

    static func selection(_ model: String, effort: String?) -> String {
        let options = effort.map { #","options":[{"id":"effort","value":"\#($0)"}]"# } ?? ""
        return #"{"instanceId":"claudeAgent","model":"\#(model)"\#(options)}"#
    }

    static func label(_ from: String, _ to: String) -> String? {
        guard let s = ModelSwitchPresentation.modelSwitch(item(#"{"from":\#(from),"to":\#(to)}"#)) else { return "no switch" }
        return ModelSwitchPresentation.label(from: s.from, to: s.to, providers: [])
    }

    @Test func labelsOnlyWhatChanged() {
        #expect(ModelSwitchPresentation.modelSwitch(Self.item(nil)) == nil)
        // Without a catalog the slugs and stated efforts stand in for the names and labels.
        #expect(Self.label(Self.selection("opus", effort: "high"), Self.selection("sonnet", effort: "high")) == "opus → sonnet")
        #expect(Self.label(Self.selection("opus", effort: "high"), Self.selection("opus", effort: "low")) == "high → low")
        #expect(Self.label(Self.selection("opus", effort: "high"), Self.selection("sonnet", effort: "low")) == "opus high → sonnet low")
        #expect(Self.label(Self.selection("opus", effort: "high"), Self.selection("opus", effort: "high")) == nil)
        // An unstated effort on one side is no effort change.
        #expect(Self.label(Self.selection("opus", effort: nil), Self.selection("opus", effort: "low")) == nil)
    }

    @Test func theRowGrowsByTheDivider() {
        func row(_ modelSwitch: String?) -> CGFloat {
            let message = ChatMessage(id: MessageId("u1"), role: .user, text: "hi", createdAt: T3Timestamp("2026-01-01T00:00:00Z"))
            let item = TimelineItem(row: TimelineRow(id: "u1", createdAt: message.createdAt,
                kind: .message(message, projectedItem: Self.item(modelSwitch), showAssistantMeta: false,
                               showAssistantCopyButton: false, assistantCopyStreaming: false, turnDiffSummary: nil)))
            let view = UserMessageRowView()
            view.context = TimelineContext()
            view.configure(item)
            return view.height(forWidth: 600)
        }
        let plain = row(nil)
        let switched = #"{"from":\#(Self.selection("opus", effort: nil)),"to":\#(Self.selection("sonnet", effort: nil))}"#
        #expect(row(switched) == plain + HandoffDividerView.height)
    }
}
