import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// `resolvePendingHandoff` and `resolveHandoffEndpoints` against handoff.test.ts in the 3105 tree.
struct HandoffTests {
    static func run(_ id: String, _ ordinal: Int, _ instance: String, _ model: String, started: Bool = true, status: String = "completed") -> Run {
        let json = #"{"id":"\#(id)","threadId":"t","ordinal":\#(ordinal),"providerInstanceId":"\#(instance)","modelSelection":{"instanceId":"\#(instance)","model":"\#(model)"},"status":"\#(status)","requestedAt":"2026-10-14T00:00:00.000Z","startedAt":\#(started ? #""2026-10-14T00:00:01.000Z""# : "null")}"#
        return try! JSONValue(parsing: Data(json.utf8)).decode(as: Run.self)
    }

    static func provider(_ id: String, _ driver: String, group: String? = nil, newThread: Bool = false) -> ServerProvider {
        var p = ServerProvider(instanceId: ProviderInstanceId(id), driver: driver, models: [])
        p.continuationGroupKey = group
        p.requiresNewThreadForModelChange = newThread
        return p
    }

    /// A starting run with a committed handoff is the one the footer measures from (handoff.ts:26-31, 2c592a1086).
    @Test func startingHandoffRunCountsAsTheLatest() {
        let providers = [Self.provider("claudeAgent", "claudeAgent"), Self.provider("codex", "codex")]
        var starting = Self.run("r2", 2, "codex", "gpt-6", started: false, status: "starting")
        let runs = [Self.run("r1", 1, "claudeAgent", "claude-haiku-5-5"), starting]
        let codex = ModelSelection(instanceId: "codex", model: "gpt-6")
        #expect(HandoffEndpoints.pending(runs, selection: codex, providers: providers) != nil)
        starting.contextHandoffId = "handoff-1"
        #expect(HandoffEndpoints.pending([runs[0], starting], selection: codex, providers: providers) == nil)
    }

    @Test func pendingHandoffFollowsTheComposerModel() {
        let providers = [Self.provider("claudeAgent", "claudeAgent", group: "claude:a"), Self.provider("codex", "codex"),
                         Self.provider("claude2", "claudeAgent", group: "claude:a"), Self.provider("pi", "pi", newThread: true)]
        let runs = [Self.run("r1", 1, "claudeAgent", "claude-haiku-5-5"), Self.run("r2", 2, "codex", "gpt-6", status: "rolled_back"),
                    Self.run("r3", 3, "codex", "gpt-6", started: false)]
        let pick = { (i: String, m: String) in HandoffEndpoints.pending(runs, selection: ModelSelection(instanceId: ProviderInstanceId(i), model: m), providers: providers) }
        // Another driver hands off from the last started, kept run.
        #expect(pick("codex", "gpt-6") == HandoffEndpoints(from: [.init(instanceId: "claudeAgent", model: "claude-haiku-5-5")],
                                                             to: .init(instanceId: "codex", model: "gpt-6")))
        // Same instance, other model: only providers that need a new thread.
        #expect(pick("claudeAgent", "claude-opus-5-5") == nil)
        // Accounts in one continuation group resume the same native thread.
        #expect(pick("claude2", "claude-haiku-5-5") == nil)
        #expect(HandoffEndpoints.pending([Self.run("p", 1, "pi", "a")], selection: ModelSelection(instanceId: "pi", model: "b"), providers: providers) != nil)
        #expect(HandoffEndpoints.pending([], selection: ModelSelection(instanceId: "codex", model: "gpt-6"), providers: providers) == nil)
        // A provider the next send would skip shows no handoff (ChatView.tsx:3974-3985).
        var off = providers
        off[1].enabled = false
        #expect(HandoffEndpoints.pending(runs, selection: ModelSelection(instanceId: "codex", model: "gpt-6"), providers: off) == nil)
        off[1].enabled = true
        off[1].availability = "unavailable"
        #expect(HandoffEndpoints.pending(runs, selection: ModelSelection(instanceId: "codex", model: "gpt-6"), providers: off) == nil)
        #expect(HandoffEndpoints.pending(runs, selection: ModelSelection(instanceId: "gone", model: "x"), providers: providers) == nil)
    }

    @Test func legacyHandoffRecoversModelsFromRuns() throws {
        let item = try TurnItem(json: JSONValue(parsing: Data(#"{"id":"i","threadId":"t","type":"handoff","runId":"r3","ordinal":1,"status":"completed","updatedAt":"2026-10-14T00:00:00.000Z","fromProviderInstanceIds":["claudeAgent"],"toProviderInstanceId":"codex"}"#.utf8)))
        let runs = [Self.run("r1", 1, "claudeAgent", "old"), Self.run("r2", 2, "claudeAgent", "claude-haiku-5-5"),
                    Self.run("r3", 3, "codex", "gpt-6"), Self.run("r4", 4, "claudeAgent", "later")]
        let endpoints = HandoffEndpoints.resolve(item, runs: runs)
        #expect(endpoints.from == [.init(instanceId: "claudeAgent", model: "claude-haiku-5-5")])
        #expect(endpoints.to == .init(instanceId: "codex", model: "gpt-6"))
    }
}
