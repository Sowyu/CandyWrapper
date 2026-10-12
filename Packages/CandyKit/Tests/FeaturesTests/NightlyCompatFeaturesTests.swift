import AppKit
import Testing
import T3Protocol
import DesignSystem
@testable import T3Store
@testable import Features

/// Behaviour 2994 fixed that does not need a 2994 server: the compact offer's timing and the first
/// thread of a name-only project.
struct NightlyCompatFeaturesTests {
    @Test func compactOfferWaitsThePromptCacheLife() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        #expect(ComposerCompaction.offerStart(driver: "claudeAgent", usedTokens: 120_000, updatedAt: at) == at.addingTimeInterval(70 * 60))
        #expect(ComposerCompaction.offerStart(driver: "claudeAgent", usedTokens: 120_000, updatedAt: at, promptCacheTtlMs: 300_000)
            == at.addingTimeInterval(300))
        #expect(ComposerCompaction.shouldOfferResume(driver: "claudeAgent", usedTokens: 120_000, updatedAt: at, promptCacheTtlMs: 300_000,
                                                     now: at.addingTimeInterval(301)))
        #expect(!ComposerCompaction.shouldOfferResume(driver: "claudeAgent", usedTokens: 120_000, updatedAt: at, now: at.addingTimeInterval(301)))
    }

    @Test func contextWindowTakesTheNewestReportAndItsTtl() throws {
        var p = try #require(try ThreadPreview.projection(titled: ThreadPreview.commandsThread))
        // Upserts can leave an older report later in the list; the newer one by time wins.
        p.providerTurns = [
            .object(["tokenUsage": .object(["usedTokens": .number(200), "updatedAt": .string("2026-10-10T12:00:00.000Z"),
                                            "promptCacheTtlMs": .number(300_000)])]),
            .object(["tokenUsage": .object(["usedTokens": .number(100), "updatedAt": .string("2026-10-10T11:00:00.000Z")])]),
        ]
        let usage = try #require(ThreadContextWindowUsage.derive(p))
        #expect(usage.used == 200)
        #expect(usage.promptCacheTtlMs == 300_000)
    }

    /// A 2994 workflow row unfolds into its phases and members; a running phase opens by itself.
    @MainActor @Test func workflowRowUnfoldsIntoPhasesAndMembers() throws {
        let json = try JSONValue(parsing: Data(#"""
        {"id":"sub-1","status":"running","origin":"provider_native","driver":"claudeAgent","providerInstanceId":"claudeAgent",
         "childThreadId":"wf","prompt":"Review the repo","title":"Coordinator",
         "startedAt":"2026-10-10T12:00:00.000Z",
         "workflow":{"name":"Repo review","phases":[{"index":0,"title":"Scan"},{"index":1,"title":"Fix"}],
          "agents":[{"index":0,"label":"Scan sources","state":"completed","phaseIndex":0,"startedAt":1760097600000,"durationMs":65000},
                    {"index":1,"label":"Scan tests","state":"running","phaseIndex":0,"startedAt":1760097610000},
                    {"index":2,"label":"Patch greet","state":"failed","phaseIndex":1,"startedAt":1760097700000,"durationMs":5000,"result":"boom"}]}}
        """#.utf8))
        let workflow = try #require(SubagentWorkflowGroup(coordinator: json))
        let agent = try #require(ProjectedSubagent(json))
        let edge = ThreadRelationshipEdge(sourceThreadId: "current", targetThreadId: "wf", kind: .subagent, status: workflow.status)
        var row = ThreadRelationships.Lineage.Row(threadId: "wf", edge: edge, status: workflow.status, isParent: false, isSubagent: true,
                                                  isMergeTarget: false, missing: false, title: "Repo review", agent: agent, child: nil,
                                                  relationship: "Subagent")
        row.workflow = workflow
        var lineage = ThreadRelationships.Lineage()
        lineage.active = [row]
        lineage.runningCount = 1
        let v = ThreadLineageSectionView()
        v.provider = { _ in ("claudeAgent", "Claude") }
        v.lineage = lineage
        let folded = v.preferredHeight
        let rowView = try #require(v.subviews.compactMap { $0 as? ThreadLineageRowView }.first)
        let disclosure = try #require(rowView.disclosure)
        disclosure.action?()
        // Two phase headers, the running phase's two members open, the failed phase closed.
        #expect(v.preferredHeight == folded + 32 * 4)
        #expect(v.subviews.compactMap { $0 as? ThreadLineageWorkflowMemberView }.map(\.member.title) == ["Scan sources", "Scan tests"])
        v.frame = NSRect(x: 0, y: 0, width: 280, height: v.preferredHeight)
        v.layoutSubtreeIfNeeded()
        let image = Snapshot.image(of: v, size: v.frame.size, dark: true)
        try Snapshot.writePNG(image, to: URL(fileURLWithPath: "/tmp/candywrapper-fidelity/nightly-compat-workflow-lineage.png"))
    }

    @Test func nameOnlyProjectStartsItsFirstThreadLocally() {
        func mode(_ configured: String, _ source: ProjectSettingSource = .environment, root: String = "/Users/a/T3 Projects/pinball",
                  hasThreads: Bool = false) -> String {
            SettingsProjectWorkspaceDefaults.newThreadEnvMode(configured: configured, source: source, workspaceRoot: root,
                                                              newProjectsRoot: "/Users/a/T3 Projects/", projectHasThreads: hasThreads)
        }
        #expect(mode("worktree") == "local")
        #expect(mode("worktree", hasThreads: true) == "worktree")
        #expect(mode("worktree", .project) == "worktree")
        #expect(mode("worktree", .t3json) == "worktree")
        #expect(mode("worktree", root: "/Users/a/T3 Projects/pinball/sub") == "worktree")
        #expect(mode("worktree", root: "/Users/a/code/pinball") == "worktree")
        #expect(SettingsProjectWorkspaceDefaults.newThreadEnvMode(configured: "worktree", source: .environment, workspaceRoot: "/x/y",
                                                                  newProjectsRoot: nil, projectHasThreads: false) == "worktree")
    }
}
