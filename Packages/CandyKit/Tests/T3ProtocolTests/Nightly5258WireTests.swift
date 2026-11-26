import Foundation
import Testing
@testable import T3Protocol

/// Wire changes between nightly 4928 and 5258 (docs/research/nightly-diff-5258-wire.md).
struct Nightly5258WireTests {
    static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func decode<T: Decodable>(_ t: T.Type, _ s: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(s.utf8))
    }

    /// B1: clearing a bound thread sends `unbindThread` (ScheduledTasksSettings.tsx:1680), and nothing else does.
    @Test func clearingTheThreadSendsUnbind() throws {
        let list = Self.json(#"{"tasks":[{"id":"st1","title":"T","prompt":"P","enabled":true,"schedule":{"type":"interval","everyMs":900000},"projectId":"p1","threadId":"t1"}]}"#)
        let task = try #require(ScheduledTask.list(list).first)
        let draft = ScheduledTaskLogic.draft(task)
        #expect(draft.savedThreadId == "t1")
        func send(_ d: ScheduledTaskDraft) throws -> JSONValue {
            try ScheduledTaskLogic.upsertInput(d, projectId: "p1", projectExists: true, selection: ("c", "m"), storedSecret: false).get()
        }
        let kept = try send(draft)
        #expect(kept["threadId"] == .string("t1") && kept["unbindThread"] == nil)
        let cleared = try send(ScheduledTaskLogic.unbind(draft))
        #expect(cleared["threadId"] == .null && cleared["unbindThread"] == .bool(true))
        var fresh = ScheduledTaskDraft()
        fresh.title = "T"; fresh.prompt = "P"; fresh.projectId = "p1"
        #expect(try send(fresh)["unbindThread"] == nil)
    }

    /// B2: workflow agent steps stay out of thread lists (orchestrationV2.ts:195, 203-207), and `workflowRun`
    /// decodes on the shell and the full thread (:165-174, :521, :2436).
    @Test func workflowStepsAreNotListed() throws {
        let step = try Self.decode(ThreadLineage.self, #"{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"t1","workflowStep":true}"#)
        #expect(step.workflowStep == true && !step.isListedLineage)
        let plain = try Self.decode(ThreadLineage.self, #"{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"t1"}"#)
        #expect(plain.workflowStep == nil && plain.isListedLineage)
        let origin = #"{"environmentId":"e1","runId":"wr1","workflow":"release","step":"build"}"#
        let thread = try Self.decode(AppThread.self, #"{"id":"t1","title":"T","lineage":{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"t1","workflowStep":true},"workflowRun":\#(origin)}"#)
        #expect(thread.workflowRun == WorkflowOrigin(environmentId: "e1", runId: "wr1", workflow: "release", step: "build"))
        #expect(thread.lineage?.isListedLineage == false)
    }

    // MARK: Item 8, decode-only groundwork

    static func workflowRun(_ id: String, startedAt: String, status: String = "running") -> String {
        #"{"runId":"\#(id)","workflow":"release","version":1,"title":"\#(id)","status":"\#(status)","detail":null,"result":null,"#
            + #""pauses":0,"retired":false,"resumesAt":null,"parentRunId":null,"parentStep":null,"startedAt":"\#(startedAt)","#
            + #""updatedAt":"\#(startedAt)","endedAt":null}"#
    }

    /// A2: a whole list decodes as a snapshot (workflow.test.ts:12-15), and a `changed` frame folds in as
    /// `applyWorkflowRunsUpdate` does (workflow.ts:215-235).
    @Test func workflowUpdatesFoldIntoTheList() throws {
        let list = try Self.decode(WorkflowRunsUpdate.self, #"{"workflows":[],"runs":[],"questions":[]}"#)
        #expect(list == .snapshot(WorkflowRunsSnapshot()))
        let first = try Self.decode(WorkflowRunsUpdate.self, #"{"workflows":[{"name":"release","version":1,"triggers":["every 1h"]}],"runs":["#
            + Self.workflowRun("a", startedAt: "2026-11-25T10:00:00Z") + "," + Self.workflowRun("b", startedAt: "2026-11-25T09:00:00Z")
            + #"],"questions":[{"runId":"a","name":"ship","request":{"title":"Ship?"},"askedAt":"2026-11-25T10:01:00Z","thread":null}]}"#)
        var held = first.applied(to: nil)
        let change = try Self.decode(WorkflowRunsUpdate.self, #"{"_tag":"changed","runs":["#
            + Self.workflowRun("c", startedAt: "2026-11-25T11:00:00Z") + "," + Self.workflowRun("b", startedAt: "2026-11-25T09:00:00Z", status: "paused")
            + #"],"removed":["a"],"questions":[{"runId":"c","name":"go","request":{},"kind":"approval","askedAt":"2026-11-25T11:01:00Z","thread":{"threadId":"t1","environmentId":null}}],"#
            + #""closed":[{"runId":"a","name":"ship"}]}"#)
        held = change.applied(to: held)
        #expect(held.runs.map(\.runId) == ["c", "b"])
        #expect(held.runs[1].status == "paused")
        #expect(held.questions.map(\.key) == ["c\u{0}go"] && held.questions[0].thread?.threadId == "t1")
        #expect(held.workflows.first?.triggers == ["every 1h"])
        #expect(WorkflowsRPC.subscribeInput() == .object(["changes": .bool(true)]))
        let counts = try Self.decode(WorkflowCounts.self, #"{"needsYou":2,"active":3,"total":9}"#)
        #expect(counts.needsYou == 2)
        let detail = try Self.decode(WorkflowRunDetail.self, #"{"run":"# + Self.workflowRun("a", startedAt: "2026-11-25T10:00:00Z")
            + #","steps":[{"name":"build","kind":"agent","status":"completed","attempts":1,"detail":null,"threadId":"t1","environmentId":null,"#
            + #""result":{"ok":true},"said":null,"startedAt":"2026-11-25T10:00:00Z","endedAt":"2026-11-25T10:05:00Z"}],"#
            + #""references":[{"kind":"pullRequest","key":"o/r#1","address":{"number":1},"title":"Fix","url":null,"state":"open","steps":["build"],"origin":"step"}]}"#)
        #expect(detail.steps[0].threadId == "t1" && detail.references[0].state == "open")
    }

    /// A1: tracked folders on a project, repository patches on a turn diff, and the workspace answers
    /// (project.ts:56-65, checkpointDiff.ts:24-43, workspaceFolders.ts).
    @Test func multiRepositoryProjectsDecode() throws {
        let project = try Self.decode(ProjectShell.self, #"{"id":"p1","title":"P","workspaceRoot":"/w","scripts":[],"#
            + #""createdAt":"2026-11-25T00:00:00Z","updatedAt":"2026-11-25T00:00:00Z","trackedFolders":[{"path":"/w/api","name":"api","discovered":true}]}"#)
        #expect(project.trackedFolders == [ProjectTrackedFolder(path: "/w/api", name: "api", discovered: true)])
        let single = try Self.decode(ProjectShell.self, #"{"id":"p1","title":"P","workspaceRoot":"/w","scripts":[],"createdAt":"2026-11-25T00:00:00Z","updatedAt":"2026-11-25T00:00:00Z"}"#)
        #expect(single.trackedFolders == nil)
        let diff = try Self.decode(ThreadTurnDiff.self, #"{"threadId":"t1","fromTurnCount":0,"toTurnCount":1,"diff":"","#
            + #""repositories":[{"name":"api","repositoryPath":"/w/api","relativePath":"../api","diff":"diff --git a/x b/x"}]}"#)
        #expect(diff.repositories?.first?.relativePath == "../api")
        let folder = try Self.decode(TaskFolder.self, #"{"root":"/t/feat","projectId":"p1","projectRoot":"/w","anchor":"/w","projectPath":"/t/feat/w","#
            + #""projectIsWorktree":true,"repositories":[{"repositoryPath":"/w/api","worktreePath":"/t/feat/api","name":"api"}]}"#)
        #expect(folder.repositories.count == 1)
        let scan = try Self.decode(WorkspaceScanFoldersResult.self, #"{"workspaceRoot":"/w","isGitRepository":false,"codeWorkspaceFile":null,"#
            + #""folders":[{"path":"/w/api","name":"api","isGitRepository":true,"source":"child"}]}"#)
        #expect(scan.folders[0].source == "child")
        #expect(WorkspaceRPC.approveInput(projectId: "p1", approvals: [("create", "make wt"), ("remove", nil)])["approvals"]?[1]?["command"] == .null)
        #expect(WorkspaceRPC.trackFoldersFields(track: [("/w/web", "web")])["trackFolders"]?[0]?["discovered"] == nil)
        #expect(CheckpointScopeFields.repositoryPath(Self.json(#"{"kind":"manual","repositoryPath":"/w/api","label":"api"}"#)) == "/w/api")
    }

    /// A6, A4 and the small item fields.
    @Test func linkedThreadsFeedbackAndItemFields() throws {
        let pairing = try Self.decode(PeerLinkClientPairingResult.self, #"{"type":"unsupported","environmentId":"e2","label":"Box","urls":["https://box"],"reason":"version"}"#)
        #expect(pairing.reason == "version" && pairing.credential == nil)
        #expect(try Self.decode(PeerLinkRemoveResult.self, #"{"removed":true}"#).endedThere == nil)
        #expect(PeerLinkRPC.historyInput(environmentId: "e2", threadId: "t1", cursor: "c1")["cursor"] == .string("c1"))
        let request = try Self.decode(AgentFeedbackRequest.self, #"{"preview":{"kind":"bug","subject":"S","expected":"E","actual":"A","workaround":"","#
            + #""trace":{"turns":2,"textTurns":1,"truncated":false,"entries":[{"turn":1,"type":"tool","tool":"t3_thread_send","outcome":"error"}]}},"feedbackStatus":"pending"}"#)
        #expect(request.preview.trace?.entries.first?.outcome == "error")
        #expect(AgentFeedbackRPC.answerInput(threadId: "t1", turnItemId: "i1", send: true, includeConversation: true)["includeConversation"] == .bool(true))
        #expect(AgentFeedbackRPC.answerInput(threadId: "t1", turnItemId: "i1", send: false, includeConversation: true)["includeConversation"] == nil)
        let notice = try Self.decode(TurnItem.self, #"{"id":"n1","threadId":"t1","type":"system_notice","message":"Sign in","mcpSignIn":{"server":"linear"},"#
            + #""runId":null,"nodeId":null,"providerTurnId":null,"parentItemId":null,"ordinal":0,"status":"completed","updatedAt":"2026-11-25T00:00:00Z"}"#)
        #expect(notice.mcpSignInServer == "linear")
        #expect(McpSignInRPC.startInput(threadId: "t1", providerThreadId: "pt1", server: "linear")["server"] == .string("linear"))
    }
}
