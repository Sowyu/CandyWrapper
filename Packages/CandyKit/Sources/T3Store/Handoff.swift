import T3Protocol

/// A context handoff's sources and target (packages/client-runtime/src/handoff.ts).
public struct HandoffEndpoints: Hashable, Sendable {
    public struct Endpoint: Hashable, Sendable {
        public var instanceId: ProviderInstanceId
        public var model: String?
        public init(instanceId: ProviderInstanceId, model: String?) { self.instanceId = instanceId; self.model = model }
    }
    public var from: [Endpoint]
    public var to: Endpoint
    public init(from: [Endpoint], to: Endpoint) { self.from = from; self.to = to }

    /// `resolveHandoffEndpoints` (handoff.ts:44-71). Items persisted before models were stamped carry only
    /// instance ids: the handoff's own run gives the target model, the newest earlier run per source the origin.
    public static func resolve(_ item: TurnItem, runs: [Run]) -> HandoffEndpoints {
        let handoffRun = item.runId.flatMap { id in runs.first { $0.id == id } }
        let toInstance = ProviderInstanceId(item.string("toProviderInstanceId") ?? "")
        let toModel = item.string("toModel")
            ?? (handoffRun?.providerInstanceId == toInstance ? handoffRun?.modelSelection?.model : nil)
        let stamped = (item["fromModelSelections"]?.arrayValue ?? []).compactMap { v -> Endpoint? in
            guard let id = v["instanceId"]?.stringValue else { return nil }
            return Endpoint(instanceId: ProviderInstanceId(id), model: v["model"]?.stringValue)
        }
        let from = !stamped.isEmpty ? stamped : (item["fromProviderInstanceIds"]?.arrayValue ?? []).compactMap(\.stringValue).map { id in
            let instance = ProviderInstanceId(id)
            let latest = runs.filter { run in
                run.providerInstanceId == instance && handoffRun.map { run.ordinal < $0.ordinal } != false
            }.max { $0.ordinal < $1.ordinal }
            return Endpoint(instanceId: instance, model: latest?.modelSelection?.model)
        }
        return HandoffEndpoints(from: from, to: Endpoint(instanceId: toInstance, model: toModel))
    }

    /// `resolvePendingHandoff` (handoff.ts:22-42): the handoff the next send would make, nil when it makes none.
    /// `threadModel` stands in for a run cached before CandyWrapper kept run models.
    // ponytail: the thread's model for cached runs without one; drop it once ThreadCache's version moves past these caches
    public static func pending(_ runs: [Run], selection: ModelSelection?, providers: [ServerProvider], threadModel: ModelSelection? = nil) -> HandoffEndpoints? {
        guard let run = runs.last(where: { $0.startedAt != nil && $0.status != .rolledBack }),
              let from = run.modelSelection ?? threadModel, let selection else { return nil }
        let source = providers.first { $0.instanceId == from.instanceId }
        let target = providers.first { $0.instanceId == selection.instanceId }
        // A disabled or unavailable provider is one the next send would skip (ChatView.tsx:3974-3985, T3 a9af48a3d2).
        guard let target, ProviderInstanceEntry(provider: target).isSelectable else { return nil }
        let needsHandoff = from.instanceId == selection.instanceId
            ? from.model != selection.model && target.requiresNewThreadForModelChange == true
            // Accounts sharing a continuation group resume the same native thread.
            : source?.continuationGroupKey == nil || source?.driver != target.driver
                || source?.continuationGroupKey != target.continuationGroupKey
        guard needsHandoff else { return nil }
        return HandoffEndpoints(from: [Endpoint(instanceId: from.instanceId, model: from.model)],
                                to: Endpoint(instanceId: selection.instanceId, model: selection.model))
    }
}
