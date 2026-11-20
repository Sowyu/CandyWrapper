import Foundation
import Testing
import T3Protocol
@testable import T3Store
@testable import Features

/// Ports from the 4928 catch-up rows the composer agent left: #24138, #37507, the queue's `canSendRun` and #23615.
struct QueueLeftoversTests {
    /// A running turn whose user message is `text`, optionally with a running compaction and a provider session that
    /// reports `activeSteeringDuringCompaction`.
    static func projection(text: String = "fix it", compacting: Bool, steersDuringCompaction: Bool?) throws -> ThreadProjection {
        let at = "2026-11-01T00:00:00.000Z"
        let capability = steersDuringCompaction.map { #","activeSteeringDuringCompaction":\#($0)"# } ?? ""
        let compaction = compacting ? #"{"position":1,"visibility":"local","sourceThreadId":"t","sourceItemId":"c","item":{"id":"c","threadId":"t","type":"compaction","runId":"run","ordinal":1,"status":"running","updatedAt":"\#(at)"}}"# : ""
        let json = """
        {"thread":{"id":"t","title":"Thread"},
         "runs":[{"id":"run","threadId":"t","ordinal":1,"status":"running","userMessageId":"m","requestedAt":"\(at)"}],
         "messages":[{"id":"m","threadId":"t","runId":"run","role":"user","text":\(try String(decoding: JSONEncoder().encode(text), as: UTF8.self)),"streaming":false,"createdAt":"\(at)","updatedAt":"\(at)"}],
         "providerSessions":[{"id":"s","status":"running","capabilities":{"turns":{"supportsActiveSteering":true\(capability)}}}],
         "visibleTurnItems":[\(compaction)],
         "updatedAt":"\(at)"}
        """
        return try JSONDecoder().decode(ThreadProjection.self, from: Data(json.utf8))
    }

    // MARK: #24138 (composerDispatch.ts:18-41 at 4928)

    @Test func anExplicitCompactAlwaysBlocksSteering() throws {
        let p = try Self.projection(compacting: false, steersDuringCompaction: true)
        #expect(ComposerLogic.compactionBlocksSteering(p, compactCommandActive: true))
        #expect(!ComposerLogic.compactionBlocksSteering(p, compactCommandActive: false))
    }

    @Test func automaticCompactionBlocksSteeringUnlessTheProviderSteersThroughIt() throws {
        #expect(ComposerLogic.compactionBlocksSteering(try Self.projection(compacting: true, steersDuringCompaction: nil), compactCommandActive: false))
        #expect(ComposerLogic.compactionBlocksSteering(try Self.projection(compacting: true, steersDuringCompaction: false), compactCommandActive: false))
        #expect(!ComposerLogic.compactionBlocksSteering(try Self.projection(compacting: true, steersDuringCompaction: true), compactCommandActive: false))
    }

    @Test(arguments: [("/compact", true), ("/COMPACT now", true), ("/compacted", false), ("compact", false)])
    func aCompactionTheUserAskedForBlocksEvenWhenTheProviderSteersThroughIt(text: String, blocks: Bool) throws {
        let p = try Self.projection(text: text, compacting: true, steersDuringCompaction: true)
        #expect(ComposerLogic.compactionBlocksSteering(p, compactCommandActive: false) == blocks)
    }

    // MARK: #37507 (ChatComposer.tsx:2226-2240, useQueuedRunEdit.ts:457-461 at 4928)

    @Test func onlyTheOppositeActionSteersAnEditedQueuedMessage() {
        // Queue by default: Cmd+Enter steers, Enter only saves.
        #expect(ComposerLogic.queuedEditSteers(running: true, alternate: true, steerByDefault: false))
        #expect(!ComposerLogic.queuedEditSteers(running: true, alternate: false, steerByDefault: false))
        // Steer by default: the plain submit saves, and the opposite action means queue, so nothing steers.
        #expect(!ComposerLogic.queuedEditSteers(running: true, alternate: false, steerByDefault: true))
        #expect(!ComposerLogic.queuedEditSteers(running: true, alternate: true, steerByDefault: true))
        // No turn to steer into, or one that can't take a steer.
        #expect(!ComposerLogic.queuedEditSteers(running: false, alternate: true, steerByDefault: false))
        #expect(!ComposerLogic.queuedEditSteers(running: true, alternate: true, steerByDefault: false, canSteer: false))
    }

    // MARK: `canSendRun` (QueuedRunsControl.tsx:123-127 at 4928)

    @Test func aFreshContextMessageSkipsCompactionButNeverSteersIntoATurn() {
        let plain = ComposerLogic.QueueState.Item(runId: RunId("a"), messageId: nil, text: "a")
        let fresh = ComposerLogic.QueueState.Item(runId: RunId("b"), messageId: nil, text: "b", freshContext: true)
        var state = ComposerLogic.QueueState(items: [plain, fresh], activeRunId: RunId("run"), canPromoteToSteer: true)
        #expect(state.canSend(plain))
        #expect(!state.canSend(fresh))
        state.promoteSkipsCompaction = true
        #expect(state.canSend(fresh))
        let stopped = ComposerLogic.QueueState(items: [fresh], canSendNow: true)
        #expect(stopped.canSend(fresh))
    }

    // MARK: #23615 (shared/projectSettings.ts:152-166 at 4928)

    @Test func aHiddenProjectDefaultModelIsNoOverride() {
        let selection = ModelSelection(instanceId: ProviderInstanceId("codex"), model: "gpt-hidden")
        func settings(hidden: [String], custom: [JSONValue] = []) -> JSONValue {
            .object([
                "providerModelPreferences": .object(["codex": .object(["hiddenModels": .array(hidden.map(JSONValue.string))])]),
                "providerInstances": .object(["codex": .object(["config": .object(["customModels": .array(custom)])])]),
            ])
        }
        #expect(ComposerSelectionContext.visibleProjectDefault(selection, settings: settings(hidden: [])) == selection)
        #expect(ComposerSelectionContext.visibleProjectDefault(selection, settings: settings(hidden: ["gpt-hidden"])) == nil)
        // Custom models stay visible even when listed as hidden, in either entry shape.
        #expect(ComposerSelectionContext.visibleProjectDefault(selection, settings: settings(hidden: ["gpt-hidden"], custom: [.string("gpt-hidden")])) == selection)
        #expect(ComposerSelectionContext.visibleProjectDefault(selection, settings: settings(hidden: ["gpt-hidden"], custom: [.object(["slug": .string("gpt-hidden")])])) == selection)
        #expect(ComposerSelectionContext.visibleProjectDefault(nil, settings: settings(hidden: ["gpt-hidden"])) == nil)
    }
}
