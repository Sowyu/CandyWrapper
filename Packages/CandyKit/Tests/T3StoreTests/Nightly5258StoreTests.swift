import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Store-side wire changes between nightly 4928 and 5258 (docs/research/nightly-diff-5258-wire.md).
@Suite struct Nightly5258StoreTests {
    /// B2: a workflow agent step's shell decodes its run and stays out of thread lists (orchestrationV2.ts:2436).
    @Test func aWorkflowStepShellIsNotListed() throws {
        var json = baseThreadJSON
        json.removeLast() // "}"
        json += #","workflowRun":{"environmentId":"e1","runId":"wr1","workflow":"release","step":"build"}}"#
        json = json.replacingOccurrences(of: #""rootThreadId":"#, with: #""workflowStep":true,"rootThreadId":"#)
        let step = try JSONDecoder().decode(ThreadShell.self, from: Data(json.utf8))
        #expect(step.workflowRun?.step == "build")
        #expect(step.lineage.workflowStep == true && !step.lineage.isListed)
        let plain = try JSONDecoder().decode(ThreadShell.self, from: Data(baseThreadJSON.utf8))
        #expect(plain.workflowRun == nil && plain.lineage.isListed)
    }

    /// B3: a card with `fields` answers `values` keyed by name, once every field has a value; one without answers
    /// `secret` as before. Cases from T3's secretRequest.test.ts:31-68.
    /// secretRequest.test.ts:78-118 at 5258: the card's "Open {host}" link.
    @Test func secretRequestLinkFindsTheOneLink() {
        let cases: [(String, String?)] = [
            ("Open this link and sign in: https://a.dev/x?s=1. Then paste the code.", "https://a.dev/x?s=1"),
            ("Open [https://a.dev/x?s=1](https://a.dev/x?s=1) and sign in.", "https://a.dev/x?s=1"),
            ("Sign in [here](https://a.dev/login?state=abc(def)).", "https://a.dev/login?state=abc(def)"),
            ("Sign in at https://a.dev/login?state=abc(def).", "https://a.dev/login?state=abc(def)"),
            ("(Sign in at https://a.dev/login.)", "https://a.dev/login"),
            ("Open **https://a.dev/x?s=1** and sign in.", "https://a.dev/x?s=1"),
            ("Open https://a.dev/x?state=u7o_ and sign in.", "https://a.dev/x?state=u7o_"),
            ("**Sign in at https://a.dev/device**", "https://a.dev/device"),
            ("_Open https://a.dev/device_.", "https://a.dev/device"),
            ("_https://a.dev/x?state=u7o_&client_id=cli_", "https://a.dev/x?state=u7o_&client_id=cli"),
            ("Use client_id acme at https://a.dev/x?state=u7o_", "https://a.dev/x?state=u7o_"),
            ("_Sign in_ at https://a.dev/x?state=u7o_", "https://a.dev/x?state=u7o_"),
            ("_Required_: Open https://a.dev/x?state=u7o_", "https://a.dev/x?state=u7o_"),
            ("(**https://a.dev/login**)", "https://a.dev/login"),
            ("Open ***https://a.dev/device***", "https://a.dev/device"),
            ("Open **_https://a.dev/device_**", "https://a.dev/device"),
            ("Open [https://a.dev/x?s=u7o_](https://a.dev/x?s=u7o_) and sign in.", "https://a.dev/x?s=u7o_"),
            ("Open `https://a.dev/x?s=1.` and sign in.", "https://a.dev/x?s=1."),
            ("Open https://a.dev/x?s=1, then if needed https://a.dev/x?s=1 again.", "https://a.dev/x?s=1"),
            ("Open https://a.dev or https://b.dev.", nil),
            ("Open https://a.dev (also written https://a.dev/).", "https://a.dev/"),
            ("Paste the code the CLI printed.", nil),
        ]
        for (reason, href) in cases { #expect(SecretRequests.link(url: nil, reason: reason)?.href == href, "\(reason)") }
        #expect(SecretRequests.link(url: "https://auth.acme.dev/a", reason: "See https://docs.acme.dev")?.host == "auth.acme.dev")
        #expect(SecretRequests.link(url: "javascript:alert(1)", reason: "") == nil)
    }

    /// feedbackRequest.test.ts at 5258: the card's display, fields and outline lines.
    @Test func feedbackRequestPresentation() throws {
        #expect(FeedbackRequests.display(status: "pending", visibility: "local") == .pending)
        #expect(FeedbackRequests.display(status: "pending", visibility: "inherited") == .pendingElsewhere(label: "Waiting in the original thread"))
        #expect(FeedbackRequests.display(status: "cancelled", visibility: "local") == .answered(sent: false, label: "Closed without sending"))
        let trace = try JSONDecoder().decode(AgentFeedbackTrace.self, from: Data(#"{"turns":2,"textTurns":2,"truncated":false,"entries":[{"turn":1,"type":"user","length":5,"text":"Hello"},{"turn":1,"type":"tool","tool":"t3_thread_read","outcome":"error","durationMs":1500},{"turn":2,"type":"user","length":1,"text":"y"}]}"#.utf8))
        var preview = try JSONDecoder().decode(AgentFeedbackPreview.self, from: Data(#"{"kind":"bug","subject":"t3_thread_read","expected":"Items.","actual":"None.","workaround":""}"#.utf8))
        preview.trace = trace
        #expect(FeedbackRequests.fields(preview).map(\.label) == ["Kind", "About", "Expected", "Happened"])
        #expect(FeedbackRequests.traceLines(trace).map(\.line) == ["Turn 1 · You · 5 characters", "Turn 1 · t3_thread_read · error · 1.5 s", "Turn 2 · You · 1 character"])
        let older = try JSONDecoder().decode(AgentFeedbackTrace.self, from: Data(#"{"turns":5,"textTurns":1,"truncated":false,"entries":[{"turn":4,"type":"user","length":5,"text":"Hello"},{"turn":5,"type":"tool","tool":"shell","outcome":"ok"}]}"#.utf8))
        #expect(FeedbackRequests.traceSummary(older) == "Outline of 5 recent turns, message text of the last 2 turns")
        #expect(FeedbackRequests.conversationHint(older) == "Adds the text of your messages and the agent's replies in the last 2 turns.")
        #expect(TurnItemType.feedbackRequest.isKnown)
    }

    @Test func multiFieldSecretRequestsAnswerValues() throws {
        let item = turnItem(#"{"id":"item","threadId":"thread","type":"secret_request","label":"Login","reason":"","delivery":"file","secretStatus":"pending","fields":[{"name":"email","label":"Email","secret":false},{"name":"password","label":"Password"}]}"#)
        let fields = try #require(item.secretRequestFields)
        let inputs = SecretRequests.inputs(label: "Login", placeholder: nil, fields: fields)
        #expect(inputs.map(\.key) == ["email", "password"] && inputs.map(\.secret) == [false, true])
        let sent = SecretRequests.answerInput(threadId: "thread", itemId: "item", fields: fields,
                                              .values(["email": "a@acme.dev ", "password": "pw"]))
        #expect(sent?["answer"] == .object(["type": .string("save"), "values": .object(["email": .string("a@acme.dev"), "password": .string("pw")])]))
        #expect(SecretRequests.answerInput(threadId: "thread", itemId: "item", fields: fields, .values(["email": "a@acme.dev"])) == nil)
        let named = [TurnItem.SecretRequestField(name: "constructor", label: "Key")]
        #expect(SecretRequests.answerInput(threadId: "t", itemId: "i", fields: named, .values([:])) == nil)
        #expect(SecretRequests.privacyNote(delivery: "file", multiple: true) == "Kept out of chat, in private files this agent's commands can read for 24 hours")

        // A 4928 card has no fields and keeps the single-secret answer.
        let single = SecretRequests.inputs(label: "Token", placeholder: nil, fields: nil)
        #expect(single == [SecretRequests.Input(key: "", label: "Token", placeholder: "Paste the secret", secret: true)])
        #expect(SecretRequests.answerInput(threadId: "t", itemId: "i", .values(["": " t "]))?["answer"]
            == .object(["type": .string("save"), "secret": .string("t")]))
    }

    static func projection(runs: String, attempts: String = "[]", sessions: String = "[]", providerThreads: String = "[]",
                           providerTurns: String = "[]") -> ThreadProjection {
        decode(ThreadProjection.self, """
            {"thread":{"id":"thread-1","title":"T"},"runs":\(runs),"attempts":\(attempts),"nodes":[],"subagents":[],
             "providerSessions":\(sessions),"providerThreads":\(providerThreads),"providerTurns":\(providerTurns),
             "runtimeRequests":[],"messages":[],"plans":[],"turnItems":[],"checkpointScopes":[],"checkpoints":[],
             "contextHandoffs":[],"contextTransfers":[],"visibleTurnItems":[],"updatedAt":"2026-01-01T00:00:00.000Z"}
            """)
    }

    static func run(_ id: String, _ status: String, continues: String? = nil) -> String {
        #"{"id":"\#(id)","threadId":"thread-1","ordinal":1,"providerInstanceId":"codex","providerThreadId":"pt1","status":"\#(status)","#
            + #""requestedAt":"2026-01-01T00:00:00.000Z""# + (continues.map { #","manualContinuationOfRunId":"\#($0)""# } ?? "") + "}"
    }

    static func session(nativeResume: Bool?, phase: String? = nil, phaseThread: String? = nil) -> String {
        let resume = nativeResume.map { #","supportsNativeResume":\#($0)"# } ?? ""
        let p = phase.map { #","startupPhase":"\#($0)""# } ?? ""
        let t = phaseThread.map { #","startupPhaseThreadId":"\#($0)""# } ?? ""
        return #"[{"id":"s1","providerInstanceId":"codex","status":"ready","capabilities":{"turns":{"supportsInterrupt":true\#(resume)}}\#(p)\#(t)}]"#
    }

    /// A7: Resume hides for a session reporting `supportsNativeResume: false` unless a message was never delivered
    /// (threadExecution.ts:425-446, orchestrationV2ManualContinuation.ts). Absent keeps Resume, as on 4928.
    @Test func resumeFollowsNativeResume() {
        let threads = #"[{"id":"pt1","providerSessionId":"s1"}]"#
        let delivered = #"[{"id":"a1","runId":"r1","attemptOrdinal":1,"rootNodeId":"n1","status":"interrupted"}]"#
        let turns = #"[{"id":"t1","runAttemptId":"a1","status":"interrupted"}]"#
        let r1 = RunId(rawValue: "r1")
        // Delivered, no native resume: nothing to resend, so no Resume.
        #expect(RunStartup.resumeUnavailable(r1, in: Self.projection(runs: "[\(Self.run("r1", "interrupted"))]", attempts: delivered,
            sessions: Self.session(nativeResume: false), providerThreads: threads, providerTurns: turns)))
        // The provider dropped the prompt: the message is unsent and can be resent.
        let dropped = #"[{"id":"t1","runAttemptId":"a1","status":"failed","promptDropped":true}]"#
        #expect(!RunStartup.resumeUnavailable(r1, in: Self.projection(runs: "[\(Self.run("r1", "interrupted"))]", attempts: delivered,
            sessions: Self.session(nativeResume: false), providerThreads: threads, providerTurns: dropped)))
        // Native resume, or a 4928 session without the flag, keeps Resume.
        for flag in [true, nil] as [Bool?] {
            #expect(!RunStartup.resumeUnavailable(r1, in: Self.projection(runs: "[\(Self.run("r1", "interrupted"))]", attempts: delivered,
                sessions: Self.session(nativeResume: flag), providerThreads: threads, providerTurns: turns)))
        }
        // A continuation of a run that never delivered follows the chain to it.
        let chain = "[\(Self.run("r0", "interrupted")),\(Self.run("r1", "interrupted", continues: "r0"))]"
        #expect(!RunStartup.resumeUnavailable(r1, in: Self.projection(runs: chain, sessions: Self.session(nativeResume: false),
            providerThreads: threads)))
    }

    /// A7: the startup phase names this thread's start, and labels follow `providerStartingPhase` (:119-135).
    @Test func startupPhaseLabels() {
        let tid = ThreadId(rawValue: "thread-1")
        let mine = Self.json(Self.session(nativeResume: nil, phase: "mcp"))[0]
        let other = Self.json(Self.session(nativeResume: nil, phase: "mcp", phaseThread: "thread-9"))[0]
        #expect(RunStartup.startupPhase(mine, threadId: tid) == "mcp")
        #expect(RunStartup.startupPhase(other, threadId: tid) == nil)
        let p = Self.projection(runs: "[\(Self.run("r1", "starting"))]", sessions: Self.session(nativeResume: nil, phase: "plugins"))
        #expect(RunStartup.providerStarting(for: p.runs[0], in: p) == .init(label: "Loading Codex plugins", driver: "codex"))
        // A finished run, or a driver with no display name, says nothing more than "Starting".
        let done = Self.projection(runs: "[\(Self.run("r1", "completed"))]", sessions: Self.session(nativeResume: nil, phase: "plugins"))
        #expect(RunStartup.providerStarting(for: done.runs[0], in: done) == nil)
        #expect(RunStartup.ProviderStarting(driver: "custom-acp") == .init(label: "Starting", driver: nil))
        // The Thinking row names the step and carries the driver for the logo (TimelineWorkGroupRows.tsx:458-474).
        let thinking = TimelineRows.derive(TimelineRowsInput(projection: p)).compactMap { row -> String? in
            if case .thinking(_, _, _, let label, let driver) = row.kind { return "\(label ?? "") \(driver ?? "")" }
            return nil
        }
        #expect(thinking == ["Loading Codex plugins codex"])
        #expect(RunStartup.startingLabel(phase: "plugins", provider: "Codex") == "Loading Codex plugins")
        #expect(RunStartup.startingLabel(phase: "connecting", provider: "Cursor") == "Connecting to Cursor")
        #expect(RunStartup.startingLabel(phase: "warming", provider: "Claude") == "Starting Claude")
        let attempt = decode(RunAttempt.self, #"{"id":"a1","runId":"r1","attemptOrdinal":1,"rootNodeId":"n1","status":"running","startedModes":{"runtimeMode":"full-access","interactionMode":"plan"}}"#)
        #expect(attempt.startedModes?.interactionMode == "plan")
    }

    static func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
}
