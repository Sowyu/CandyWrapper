import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The Lineage graph, ordering and grouping (packages/client-runtime/src/state/threadRelationships.test.ts), merge
/// back and session detach (threadWorkflows.ts), and the subagent labels (subagentDisplay.ts, orchestrationTiming.ts).
@Suite struct ThreadRelationshipsTests {
    /// A projection for thread `id` with the given thread fields and arrays (JSON fragments).
    private func projection(_ id: String, thread extra: String = "", runs: String = "[]", subagents: String = "[]",
                            transfers: String = "[]", sessions: String = "[]", providerThreads: String = "[]") -> ThreadProjection {
        let thread = "{\"id\":\"\(id)\",\"title\":\"T\"\(extra.isEmpty ? "" : "," + extra)}"
        return try! JSONDecoder().decode(ThreadProjection.self, from: Data("""
            {"thread":\(thread),"runs":\(runs),"attempts":[],"nodes":[],"subagents":\(subagents),
             "providerSessions":\(sessions),"providerThreads":\(providerThreads),"providerTurns":[],"runtimeRequests":[],
             "messages":[],"plans":[],"turnItems":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],
             "contextTransfers":\(transfers),"visibleTurnItems":[],"updatedAt":"2026-01-01T00:00:00.000Z"}
            """.utf8))
    }

    private func child(_ id: String, of parent: String, _ relation: LineageRelationship, created: String = "2026-06-20T00:00:00.000Z",
                       status: ThreadStatus = .completed, activity: ThreadStatus? = nil,
                       _ edit: (inout ThreadShell) -> Void = { _ in }) -> ThreadShell {
        thread(id) {
            edit(&$0)
            $0.lineage.parentThreadId = ThreadId(parent)
            $0.lineage.relationshipToParent = relation
            $0.status = status
            $0.activityRunStatus = activity
            $0.createdAt = T3Timestamp(created)
        }
    }

    @Test func parentLinkNamesOnlyASubagentParent() {
        let parent = thread("parent") { $0.title = "Plan the release" }
        let sub = child("sub", of: "parent", .subagent), fork = child("fork", of: "parent", .fork)
        #expect(ThreadRelationships.parentLink(sub.lineage, threads: [parent, sub])?.title == "Plan the release")
        #expect(ThreadRelationships.parentLink(sub.lineage, threads: [parent, sub])?.threadId == "parent")
        #expect(ThreadRelationships.parentLink(sub.lineage, threads: [sub])?.title == "Parent thread")
        #expect(ThreadRelationships.parentLink(fork.lineage, threads: [parent, fork]) == nil)
        #expect(ThreadRelationships.parentLink(nil, threads: [parent]) == nil)
    }

    @Test(arguments: [("running", "completed"), ("completed", "running"), ("waiting", "failed"), ("interrupted", "pending")])
    func parentStatusIsIndependentOfTheChild(_ parentStatus: String, _ childStatus: String) {
        let parent = thread("parent") { $0.activityRunStatus = ThreadStatus(rawValue: parentStatus); $0.status = .cancelled }
        let kid = child("child", of: "parent", .fork, activity: ThreadStatus(rawValue: childStatus))
        let g = ThreadRelationships.graph(threads: [parent, kid], projection: nil)
        #expect(ThreadRelationships.rowStatus(g, ThreadRelationships.immediate(g, "child")[0]) == parentStatus)
        #expect(ThreadRelationships.rowStatus(g, ThreadRelationships.immediate(g, "parent")[0]) == childStatus)
    }

    @Test func aMissingParentIsNotLabelledWithItsChildsStatus() {
        let g = ThreadRelationships.graph(threads: [child("child", of: "missing", .subagent, status: .running)], projection: nil)
        #expect(g.nodes["missing"]?.missing == true)
        #expect(ThreadRelationships.rowStatus(g, ThreadRelationships.immediate(g, "child")[0]) == nil)
    }

    @Test func aRunForkPointsAtItsSourceThread() {
        let fork = thread("fork") {
            $0.forkedFrom = ForkedFrom(type: "run", threadId: "source", runId: "run-1")
            $0.lineage.parentThreadId = "other"
            $0.lineage.relationshipToParent = .fork
            $0.activityRunStatus = .running
            $0.status = .cancelled
        }
        let g = ThreadRelationships.graph(threads: [fork], projection: nil)
        #expect(g.edges == [ThreadRelationshipEdge(sourceThreadId: "source", targetThreadId: "fork", kind: .fork, status: "running")])
    }

    @Test func subagentAndTransferEdgesComeFromTheProjection() {
        let p = projection("parent", subagents: """
            [{"id":"n1","childThreadId":"kid","status":"completed","prompt":"Find the bug","title":null,"origin":"app_owned",
              "driver":"codex","providerInstanceId":"codex","model":"gpt-5.4","result":"Done","startedAt":null,"completedAt":null}]
            """, transfers: """
            [{"sourceThreadId":"parent","targetThreadId":"target","status":"consumed"},
             {"sourceThreadId":"parent","targetThreadId":"parent","status":"pending"}]
            """)
        let kid = child("kid", of: "parent", .subagent, activity: .running)
        let g = ThreadRelationships.graph(threads: [thread("parent"), kid], projection: p)
        // The child's live run outranks the settled task.
        #expect(g.edges.contains(ThreadRelationshipEdge(sourceThreadId: "parent", targetThreadId: "kid", kind: .subagent, status: "running")))
        #expect(g.edges.contains(ThreadRelationshipEdge(sourceThreadId: "parent", targetThreadId: "target", kind: .transfer, status: "consumed")))
        #expect(!g.edges.contains { $0.targetThreadId == "parent" })
    }

    /// 321b86b05d: a supervisor still waiting on its worker shows as running; a settled one takes the child's later run.
    @Test(arguments: [("running", "running"), ("completed", "failed")])
    func activeSupervisorOutranksTheChildsLatestRun(_ agentStatus: String, _ expected: String) {
        let p = projection("parent", subagents: """
            [{"id":"n1","childThreadId":"kid","status":"\(agentStatus)","title":null,"origin":"provider_native",
              "driver":"claudeAgent","providerInstanceId":"claude","startedAt":null,"completedAt":null}]
            """)
        let kid = child("kid", of: "parent", .subagent, status: .failed) { $0.latestRunId = RunId("r2") }
        let g = ThreadRelationships.graph(threads: [thread("parent"), kid], projection: p)
        #expect(g.edges.first { $0.targetThreadId == "kid" }?.status == expected)
        let agent = ProjectedSubagent(p.subagents[0])
        let live = child("kid", of: "parent", .subagent, activity: .waiting)
        #expect(agent?.following(live).status == (agentStatus == "running" ? "running" : "waiting"))
    }

    @Test func theLiveShellWinsOverAnArchivedCopy() {
        let live = child("kid", of: "parent", .fork)
        let archived = child("kid", of: "parent", .fork, status: .failed)
        let g = ThreadRelationships.graph(threads: [live, archived], projection: nil)
        #expect(g.nodes["kid"]?.thread?.status == .completed)
    }

    @Test func mergeBackTargetsOnlyForksAndPrefersTheRecordedSource() {
        #expect(ThreadRelationships.mergeBackTarget(projection("a")) == nil)
        let sub = projection("a", thread: #""lineage":{"parentThreadId":"p","relationshipToParent":"subagent","rootThreadId":"p"}"#)
        #expect(ThreadRelationships.mergeBackTarget(sub) == nil)
        let fork = projection("a", thread: #""lineage":{"parentThreadId":"p","relationshipToParent":"fork","rootThreadId":"p"}"#)
        #expect(ThreadRelationships.mergeBackTarget(fork) == "p")
        let recorded = projection("a", thread: """
            "lineage":{"parentThreadId":"p","relationshipToParent":"fork","rootThreadId":"p"},"forkedFrom":{"type":"run","threadId":"src","runId":"r"}
            """)
        #expect(ThreadRelationships.mergeBackTarget(recorded) == "src")
    }

    @Test func linesUpParentThenMergeTargetThenNewestFirst() {
        let me = child("me", of: "parent", .fork, created: "2026-06-20T00:00:05.000Z")
        let older = child("older", of: "me", .fork, created: "2026-06-20T00:00:01.000Z")
        let newer = child("newer", of: "me", .fork, created: "2026-06-20T00:00:09.000Z")
        let tieB = child("tie-b", of: "me", .fork, created: "2026-06-20T00:00:03.000Z")
        let tieA = child("tie-a", of: "me", .fork, created: "2026-06-20T00:00:03.000Z")
        let g = ThreadRelationships.graph(threads: [older, me, newer, tieB, tieA, child("lost", of: "me", .fork)] , projection: nil)
        var rows = ThreadRelationships.immediate(g, "me")
        rows.append(ThreadRelationshipRow(threadId: "ghost", fromThreadId: "me", depth: 1,
                                          edge: ThreadRelationshipEdge(sourceThreadId: "me", targetThreadId: "ghost", kind: .transfer, status: nil)))
        let order = ThreadRelationships.orderLineage(g, rows, current: "me", mergeTarget: "older").map(\.threadId.rawValue)
        // "lost" has the fixture's createdAt (June 20 00:00), so it sorts as oldest; "ghost" has no shell and sinks.
        #expect(order == ["parent", "older", "newer", "tie-a", "tie-b", "lost", "ghost"])
    }

    /// The prefilter keeps every shell the lineage reads, so the lineage over it equals the lineage over all shells.
    @Test func relatedShellsGiveTheSameLineage() {
        let p = projection("me", thread: "\"lineage\":{\"parentThreadId\":\"boss\",\"rootThreadId\":\"boss\",\"relationshipToParent\":\"fork\"}",
                           subagents: """
            [{"id":"n1","childThreadId":"a1","status":"running","prompt":"x","title":null,"origin":"app_owned",
              "driver":"codex","providerInstanceId":"codex","model":null,"result":null,"startedAt":null,"completedAt":null}]
            """, transfers: "[{\"sourceThreadId\":\"me\",\"targetThreadId\":\"t1\",\"status\":\"completed\"}]")
        func scoped(_ t: ThreadShell, _ env: String = "e1") -> ThreadShell {
            var s = t
            s.id = s.id.scoped(to: env)
            s.lineage.parentThreadId = s.lineage.parentThreadId?.scoped(to: env)
            return s
        }
        let all = [thread("me") { $0.lineage.parentThreadId = "boss"; $0.lineage.relationshipToParent = .fork },
                   thread("boss") { $0.title = "Boss" }, child("a1", of: "me", .subagent, status: .running),
                   child("kid", of: "me", .fork), child("sibling", of: "boss", .fork), thread("t1"), thread("other")].map { scoped($0) }
            + [scoped(child("elsewhere", of: "me", .fork), "e2")]
        let kept = ThreadRelationships.related(all, to: ThreadId("e1:me"), projection: p)
        #expect(Set(kept.map(\.id.rawValue)) == ["e1:me", "e1:boss", "e1:a1", "e1:kid", "e1:t1"])
        let full = ThreadRelationships.lineage(threadId: "me", threads: ThreadRelationships.unscoped(all, environmentId: "e1"), projection: p)
        let fast = ThreadRelationships.lineage(threadId: "me", threads: ThreadRelationships.unscoped(kept, environmentId: "e1"), projection: p)
        #expect(full == fast)
        #expect(!full.related.isEmpty)
    }

    @Test func groupsRelatedActiveAndPreviousAgents() {
        let p = projection("me", runs: """
            [{"id":"r1","threadId":"me","ordinal":1,"status":"completed","requestedAt":"2026-01-01T00:00:00.000Z"}]
            """, subagents: """
            [{"id":"n1","childThreadId":"a1","status":"running","prompt":"Run tests","title":"Subagent: /root/run_the_tests","origin":"app_owned",
              "driver":"codex","providerInstanceId":"codex","model":null,"result":null,"startedAt":"2026-01-01T00:00:00.000Z","completedAt":null},
             {"id":"n2","childThreadId":"a2","status":"failed","prompt":"Lint","title":null,"origin":"provider_native",
              "driver":"claudeAgent","providerInstanceId":"claude","model":null,"result":"boom","startedAt":null,"completedAt":null},
             {"id":"n3","childThreadId":null,"status":"running","prompt":"Spawning","title":null,"origin":"app_owned",
              "driver":"codex","providerInstanceId":"codex","model":null,"result":null,"startedAt":null,"completedAt":null}]
            """)
        let threads = [thread("me") { $0.lineage.parentThreadId = "boss"; $0.lineage.relationshipToParent = .subagent },
                       thread("boss") { $0.title = "Boss" },
                       { var a = child("a1", of: "me", .subagent, status: .running); a.title = "Subagent: /root/run_the_tests"; return a }(),
                       child("a2", of: "me", .subagent, status: .failed)]
        let l = ThreadRelationships.lineage(threadId: "me", threads: threads, projection: p)
        #expect(l.related.map(\.threadId) == ["boss"])
        #expect(l.related[0].isParent && l.related[0].relationship == "Parent agent")
        #expect(l.active.map(\.threadId) == ["a1"])
        #expect(l.active[0].title == "Run The Tests")
        #expect(l.active[0].canStop)
        #expect(l.previous.map(\.threadId) == ["a2"])
        #expect(l.previous[0].failed)
        // One running child row plus one task that has no child thread yet.
        #expect(l.runningCount == 2)
        #expect(l.title == "Lineage · 2 running")
    }

    @Test func mergeBackUsesTheNewestFinishedRunUnlessANewerOneRuns() {
        func runs(_ list: [(Int, String)]) -> ThreadProjection {
            projection("f", runs: "[" + list.map { #"{"id":"r\#($0.0)","threadId":"f","ordinal":\#($0.0),"status":"\#($0.1)","requestedAt":"2026-01-01T00:00:00.000Z"}"# }.joined(separator: ",") + "]")
        }
        #expect(ThreadRelationships.latestMergeBackRun(runs([(1, "completed"), (2, "waiting")]))?.id == "r2")
        #expect(ThreadRelationships.latestMergeBackRun(runs([(1, "completed"), (2, "running")])) == nil)
        #expect(ThreadRelationships.latestMergeBackRun(runs([(1, "completed"), (2, "failed")]))?.id == "r1")
        #expect(ThreadRelationships.latestMergeBackRun(runs([(1, "queued")])) == nil)
    }

    @Test func detachNeedsALiveSession() {
        let stopped = projection("t", sessions: #"[{"id":"s1","status":"stopped"}]"#)
        #expect(!ThreadRelationships.canDetachSession(stopped))
        let ready = projection("t", sessions: #"[{"id":"s1","status":"stopped"},{"id":"s2","status":"ready"}]"#)
        #expect(ThreadRelationships.canDetachSession(ready))
        let attached = projection("t", sessions: #"[{"id":"s1","status":"error"},{"id":"s2","status":"ready"}]"#,
                                  providerThreads: #"[{"id":"pt","appThreadId":"t","providerSessionId":"s1"}]"#)
        #expect(!ThreadRelationships.canDetachSession(attached))
    }

    @Test func labelsAndTimes() {
        #expect(ThreadRelationships.statusLabel("in_progress") == "Running")
        #expect(ThreadRelationships.statusLabel("resolved_portable") == "Resolved (portable)")
        #expect(ThreadRelationships.statusLabel(nil) == "Unknown")
        #expect(ThreadRelationships.subagentDisplayTitle("Subagent: Find the bug") == "Find the bug")
        #expect(ThreadRelationships.subagentDisplayTitle("/root/explorer/check_db_schema") == "Check Db Schema")
        #expect(ThreadRelationships.compactElapsed(seconds: 45.9) == "45s")
        #expect(ThreadRelationships.compactElapsed(seconds: 12 * 60) == "12m")
        #expect(ThreadRelationships.compactElapsed(seconds: 90 * 60) == "1.5h")
        #expect(ThreadRelationships.compactElapsed(seconds: 60 * 60) == "1h")
        #expect(ThreadRelationships.compactElapsed(seconds: 14 * 3600) == "14h")
        #expect(ThreadRelationships.elapsed(seconds: 65) == "1m 05s")
        #expect(ThreadRelationships.elapsed(seconds: 3900) == "1h 05m")
        #expect(ThreadRelationships.formatDuration(4_250) == "4.3s")
        #expect(ThreadRelationships.formatDuration(125_000) == "2m 5s")
        let done = ThreadRelationships.SubagentStatus(status: "completed", startedAt: "2026-01-01T00:00:00.000Z", completedAt: "2026-01-01T00:00:34.400Z")
        #expect(ThreadRelationships.formatSubagentStatus(done, nowMs: 0) == "Completed in 34s")
        let live = ThreadRelationships.SubagentStatus(status: "running", startedAt: "2026-01-01T00:00:00.000Z", completedAt: nil)
        #expect(ThreadRelationships.formatSubagentStatus(live, nowMs: ms("2026-01-01T00:00:12.900Z")) == "Working 12s")
        #expect(ThreadRelationships.formatSubagentStatus(.init(status: "failed", startedAt: nil, completedAt: nil), nowMs: 0) == "Failed")
        #expect(ThreadRelationships.formatSubagentStatus(nil, nowMs: 0) == "Starting")
        #expect(ThreadRelationships.modelSlugName("claude-haiku-4-5") == "Claude Haiku 4.5")
        #expect(ThreadRelationships.modelSlugName("openrouter/claude-sonnet-4-5-20250929") == "openrouter/Claude Sonnet 4.5 20250929")
        #expect(ThreadRelationships.modelSlugName("my-model") == "my-model")
        #expect(ThreadRelationships.subagentElapsedMs(status: "completed", startedAt: "2026-01-01T00:00:00.000Z", completedAt: nil, nowMs: 5) == nil)
    }
}

@Suite struct SecretRequestsTests {
    @Test func displayFollowsStatusAndVisibility() {
        #expect(SecretRequests.display(status: "pending", visibility: "local") == .pending)
        #expect(SecretRequests.display(status: "pending", visibility: "inherited") == .pendingElsewhere(label: "Waiting for an answer in the original thread"))
        #expect(SecretRequests.display(status: "saved", visibility: "local") == .answered(outcome: .saved, label: "Saved securely and kept private"))
        #expect(SecretRequests.display(status: "cancelled", visibility: "local") == .answered(outcome: .ended, label: "Request ended"))
    }

    @Test func answerTrimsAndRefusesBlank() {
        #expect(SecretRequests.answerInput(threadId: "t", itemId: "i", .save("   ")) == nil)
        let save = SecretRequests.answerInput(threadId: "t", itemId: "i", .save("  abc \n"))
        #expect(save?["answer"]?["secret"]?.stringValue == "abc")
        #expect(save?["turnItemId"]?.stringValue == "i")
        #expect(SecretRequests.answerInput(threadId: "t", itemId: "i", .decline)?["answer"]?["type"]?.stringValue == "decline")
    }

    @Test func onlyKnownErrorsReachTheCard() {
        #expect(SecretRequests.failureMessage(tag: "SecretRequestError", message: "Request expired.") == "Request expired.")
        #expect(SecretRequests.failureMessage(tag: "RpcClientError", message: "value abc123") == SecretRequests.genericFailure)
        #expect(SecretRequests.failureMessage(tag: "SecretRequestError", message: "  ") == SecretRequests.genericFailure)
    }
}
