import Foundation
import T3Protocol
import T3Store

/// `ModelSwitchRow` (chat/V2LifecycleRow.tsx:640-662 at 4928, #28995): a divider above your message when the model
/// or the effort changed with it, labeled "<from> → <to>" with only what changed.
enum ModelSwitchPresentation {
    /// `user_message.modelSwitch`, read from the item's JSON.
    // ponytail: decoded here from `raw`; move to the item's decoded fields once T3Protocol carries `modelSwitch`
    static func modelSwitch(_ item: ProjectedTurnItem?) -> (from: ModelSelection, to: ModelSelection)? {
        guard let item, item.item.type == .userMessage, let value = item.item.raw["modelSwitch"],
              let from = try? value["from"]?.decode(as: ModelSelection.self),
              let to = try? value["to"]?.decode(as: ModelSelection.self) else { return nil }
        return (from, to)
    }

    /// The divider's label, or nil when neither the model nor the effort visibly changed
    /// (`resolveModelSwitchChange`, packages/client-runtime/src/handoff.ts at 4928).
    static func label(from: ModelSelection, to: ModelSelection, providers: [ServerProvider]) -> String? {
        let fromModel = model(from, providers), toModel = model(to, providers)
        let fromEffort = effort(from, fromModel), toEffort = effort(to, toModel)
        let modelChanged = from.model != to.model
        let effortChanged = fromEffort != nil && toEffort != nil && fromEffort?.value != toEffort?.value
        guard modelChanged || effortChanged else { return nil }
        func describe(_ selection: ModelSelection, _ model: ServerProviderModel?, _ effort: String?) -> String {
            let driver = providers.first { $0.instanceId == selection.instanceId }?.driver
            let name = model.map { ModelNames.trigger($0, driver: driver) } ?? selection.model
            return [modelChanged ? name : nil, effortChanged ? effort : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        return "\(describe(from, fromModel, fromEffort?.label)) → \(describe(to, toModel, toEffort?.label))"
    }

    private static func model(_ selection: ModelSelection, _ providers: [ServerProvider]) -> ServerProviderModel? {
        providers.first { $0.instanceId == selection.instanceId }?.models.first { $0.slug == selection.model }
    }

    /// `REASONING_DESCRIPTOR_IDS` (client-runtime modelTraits.ts:12-15 at 4928).
    // ponytail: no `role: "reasoning"` check, CW doesn't decode the descriptor role; add it when a provider relies on it
    static let reasoningIds = Set(ModelTraits.reasoningEffortIds + ["thinking"])

    /// `resolveEffort`: the model's reasoning select, or the stated value when the catalog lacks the model.
    static func effort(_ selection: ModelSelection, _ model: ServerProviderModel?) -> (value: String, label: String)? {
        let stated = ((try? selection.options?.decode(as: [ProviderOptionSelection].self)) ?? nil) ?? []
        guard let model else {
            // Pi states its effort as `thinking`.
            for id in ModelTraits.reasoningEffortIds + ["thinking"] {
                if let value = stated.first(where: { $0.id == id })?.value.string { return (value, value) }
            }
            return nil
        }
        let resolved = ModelTraits.descriptors(model, selections: stated)
        guard let descriptor = resolved.first(where: { $0.type == .select && reasoningIds.contains($0.id) }),
              let value = ModelTraits.currentValue(descriptor)?.string else { return nil }
        return (value, descriptor.options.first { $0.id == value }?.label ?? value)
    }
}
