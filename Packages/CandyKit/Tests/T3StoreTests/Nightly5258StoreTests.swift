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
        #expect(RunStartup.startupPhase(for: p.runs[0], in: p, items: []) == "plugins")
        #expect(RunStartup.startingLabel(phase: "plugins", provider: "Codex") == "Loading Codex plugins")
        #expect(RunStartup.startingLabel(phase: "connecting", provider: "Cursor") == "Connecting to Cursor")
        #expect(RunStartup.startingLabel(phase: "warming", provider: "Claude") == "Starting Claude")
        let attempt = decode(RunAttempt.self, #"{"id":"a1","runId":"r1","attemptOrdinal":1,"rootNodeId":"n1","status":"running","startedModes":{"runtimeMode":"full-access","interactionMode":"plan"}}"#)
        #expect(attempt.startedModes?.interactionMode == "plan")
    }

    static func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
}
