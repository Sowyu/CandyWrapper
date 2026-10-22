import AppKit
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// The draft's first send and the diff panel's failure state, both checked against the official
/// web client on the sandbox (2026-10-10).
@MainActor
struct LaunchAndDiffStateTests {
    /// The web client's `orchestration.launchThread` payload from a fresh "Current checkout" draft,
    /// captured from its socket (ids replaced). No branch: the toolbar shows the checkout's branch
    /// but the draft never stores it in local mode.
    @Test func launchPayloadMatchesWebClient() throws {
        let web = #"""
        {"commandId":"c1","creationSource":"web","threadId":"t1","projectId":"p1","title":"x","generateTitle":true,
         "modelSelection":{"instanceId":"claudeAgent","model":"claude-haiku-5-5"},"runtimeMode":"full-access",
         "interactionMode":"default","workspaceStrategy":{"type":"root"},
         "initialMessage":{"messageId":"m1","text":"x","attachments":[]}}
        """#
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(web.utf8))
        let ours = ComposerLogic.launchThreadPayload(
            commandId: "c1", threadId: "t1", projectId: "p1", title: "x",
            modelSelection: .object(["instanceId": .string("claudeAgent"), "model": .string("claude-haiku-5-5")]),
            runtimeMode: "full-access", interactionMode: "default", messageId: "m1", text: "x")
        #expect(ours == expected)
    }

    struct Failed: LocalizedError { var errorDescription: String? }

    private func panel(_ result: @escaping @Sendable () throws -> String) -> DiffPanelView {
        let panel = DiffPanelView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        panel.threadId = "t1"
        panel.loader = { _ in
            let json = try JSONSerialization.data(withJSONObject: ["threadId": "t1", "fromTurnCount": 8, "toTurnCount": 9, "diff": try result()])
            return try JSONDecoder().decode(ThreadTurnDiff.self, from: json)
        }
        panel.setSummaries([TurnDiffSummary(checkpointId: "c9", scopeId: "scope", runId: "run9", checkpointTurnCount: 9, checkpointRef: "ref",
                                            status: "ready", files: [], assistantMessageId: nil, completedAt: "2026-10-10T00:00:09Z")])
        return panel
    }

    private func settle(_ panel: DiffPanelView) async throws {
        _ = await eventually { panel.message.text != "Loading checkpoint diff..." }
        panel.layoutSubtreeIfNeeded()
    }

    /// An interrupted latest run: its checkpoint is ready but the server's turn count stops at the
    /// last completed run, so getTurnDiff fails. T3 shows the error's message in red at the top and
    /// "No patch available for this selection." centered below (DiffPanel.tsx:1093-1117).
    @Test func failedTurnDiffShowsErrorAndNoPatch() async throws {
        let panel = panel { throw Failed(errorDescription: "Failed to load turn diff") }
        try await settle(panel)
        #expect(panel.errorLine.isHidden == false)
        #expect(panel.errorLine.text == "Failed to load turn diff")
        #expect(panel.message.text == "No patch available for this selection.")
        #expect(panel.message.frame.minY > panel.errorLine.frame.maxY)
    }

    @Test func emptyTurnDiffShowsNoNetChanges() async throws {
        let panel = panel { "" }
        try await settle(panel)
        #expect(panel.errorLine.isHidden)
        #expect(panel.message.text == "No net changes in this selection.")
    }
}
