import Foundation
import T3Protocol

// The composer's model, traits and access state per thread, and the exact values the next send
// carries. Nothing here talks to the server: a pick changes draft state only, and the next
// `message.dispatch` (or `launchThread`) sends the selection (I-composer-flow.md 5.3 to 5.7).
// Ported from apps/web/src/composerDraftStore.ts (modelSelectionByProvider, sticky state),
// components/ChatView.tsx:10698-10776 (onProviderModelSelect) and ChatView.logic.ts:1046-1092.

/// A model and its explicitly picked options for one provider instance.
public struct InstanceModelSelection: Codable, Hashable, Sendable {
    public var model: String
    public var options: [ProviderOptionSelection]?
    public init(model: String, options: [ProviderOptionSelection]? = nil) { self.model = model; self.options = options }
}

/// One thread's (or new-thread draft's) unsent picker state.
public struct ComposerModelDraft: Codable, Hashable, Sendable {
    public var activeInstance: ProviderInstanceId?
    public var selectionByInstance: [ProviderInstanceId: InstanceModelSelection] = [:]
    /// Set only when the user picked; seeded selections may be replaced later.
    public var explicit = false
    public var runtimeMode: RuntimeMode?
    public var interactionMode: InteractionMode?
    public init() {}
}

/// Client-global memory that seeds new drafts: the last model per instance, the last options per
/// instance and model, and the last active instance (`stickyModelSelectionByProvider` and friends).
public struct StickyModelState: Codable, Hashable, Sendable {
    public var modelByInstance: [ProviderInstanceId: InstanceModelSelection] = [:]
    public var optionsByModel: [ProviderInstanceId: [String: [ProviderOptionSelection]]] = [:]
    public var activeInstance: ProviderInstanceId?
    public init() {}
}

/// What the composer needs to know about the thread it edits.
public struct ComposerSelectionContext: Sendable {
    public var catalog: ProviderCatalog
    /// The server thread; nil for a new-thread draft.
    public var thread: ThreadShell?
    /// The project's `defaultModelSelection` and `defaultRuntimeMode` overrides.
    public var projectDefaultModel: ModelSelection?
    public var projectDefaultRuntimeMode: RuntimeMode?
    /// Server settings `defaultModelSelection` and `defaultRuntimeMode`.
    public var serverDefaults: ServerThreadDefaults
    /// The thread has a provider session (`activeRuntime !== null`); model changes may be blocked.
    public var hasStartedSession: Bool
    /// The session can hand off to another provider (`supportsProviderSwitchingViaHandoff`, true for Claude).
    public var supportsProviderHandoff: Bool
    /// The client setting `planModeEnabled` (default false). Off means interaction mode is always `default`.
    public var planModeEnabled: Bool

    public init(catalog: ProviderCatalog, thread: ThreadShell? = nil, projectDefaultModel: ModelSelection? = nil,
                projectDefaultRuntimeMode: RuntimeMode? = nil, serverDefaults: ServerThreadDefaults = ServerThreadDefaults(),
                hasStartedSession: Bool = false, supportsProviderHandoff: Bool = true, planModeEnabled: Bool = false) {
        self.catalog = catalog; self.thread = thread; self.projectDefaultModel = projectDefaultModel
        self.projectDefaultRuntimeMode = projectDefaultRuntimeMode; self.serverDefaults = serverDefaults
        self.hasStartedSession = hasStartedSession; self.supportsProviderHandoff = supportsProviderHandoff
        self.planModeEnabled = planModeEnabled
    }

    /// `resolveComposerInteractionMode(...).enabled` (ChatView.logic.ts:626-639): the setting is on and
    /// the selected provider exists and does not hide the toggle.
    public func interactionModeEnabled(_ provider: ServerProvider?) -> Bool {
        planModeEnabled && provider != nil && provider?.showInteractionModeToggle != false
    }
}

/// The selection the composer shows and the values its next send carries.
public struct ResolvedComposerSelection: Sendable {
    public let entry: ProviderInstanceEntry?
    public let instanceId: ProviderInstanceId?
    public let modelSlug: String?
    /// Nil when the slug is not in the instance's catalog (shown as is, "Unavailable").
    public let model: ServerProviderModel?
    /// The draft's explicit options (before the implicit fast mode default).
    public let options: [ProviderOptionSelection]?
    /// Descriptors with current values, for the traits menu and its label.
    public let descriptors: [ProviderOptionDescriptor]
    /// `message.dispatch.modelSelection` / `launchThread.modelSelection`. Nil when no provider is usable.
    public let modelSelection: ModelSelection?
    /// The effective mode the access control shows.
    public let runtimeMode: RuntimeMode
    public let runtimeModeOptions: [RuntimeMode]
    /// Set when an existing thread's mode must change before the send: `thread.runtime-mode.set`.
    public let runtimeModeToPersist: RuntimeMode?
    /// `message.dispatch.interactionMode`; always `default` unless plan mode is on.
    public let interactionMode: InteractionMode
    public let interactionModeToPersist: InteractionMode?

    /// The model trigger's label (`triggerTitle`, ProviderModelPicker.tsx:85-91).
    public var triggerLabel: String {
        if let model { return ModelNames.trigger(model) }
        if let first = entry?.models.first, modelSlug == nil { return ModelNames.trigger(first) }
        return modelSlug ?? "Choose model"
    }
}

/// A new thread's models when the user shift-clicks several (`draftFanoutStateAtom`, ChatView.tsx:1990-2010):
/// each send starts one thread and worktree per model (docs/user/thread-sidebar.md "Start in the background").
public enum ModelFanout {
    /// `onToggleModel` (ChatComposer.tsx:5508-5533): a shift-click adds or removes the model. Two or
    /// more stay a fan-out; one left goes back to a single pick (`single`).
    public static func toggle(_ current: [ModelSelection]?, base: ModelSelection, instance: ProviderInstanceId, model: String)
        -> (selections: [ModelSelection]?, single: ModelSelection?) {
        let list = current ?? [base]
        let matches = { (s: ModelSelection) in s.instanceId == instance && s.model == model }
        let next = list.contains(where: matches) ? list.filter { !matches($0) } : list + [ModelSelection(instanceId: instance, model: model)]
        if next.count > 1 { return (next, nil) }
        return (nil, next.first ?? base)
    }

    /// `multipleLabel` (ProviderModelPicker.tsx:179-186): two names, then "N more"; "Choose models" when empty.
    public static func triggerLabel(_ names: [String]) -> String {
        guard !names.isEmpty else { return "Choose models" }
        return names.prefix(2).joined(separator: ", ") + (names.count > 2 ? ", \(names.count - 2) more" : "")
    }

    public static func key(_ s: ModelSelection) -> String { "\(s.instanceId.rawValue):\(s.model)" }
}

/// Per-thread drafts, sticky state and favorites, persisted in UserDefaults (T3 keeps the same data
/// in localStorage: `t3code:composer-drafts:v1` and the client setting `favorites`).
@MainActor
public final class ComposerSelectionStore {
    public private(set) var drafts: [String: ComposerModelDraft] = [:]
    public private(set) var sticky = StickyModelState()
    public private(set) var favorites: [ModelFavorite] = []

    private let defaults: UserDefaults?
    static let stateKey = "CandyWrapper.composerModelState.v1"
    static let favoritesKey = "CandyWrapper.modelFavorites.v1"

    private struct Persisted: Codable {
        var drafts: [String: ComposerModelDraft]
        var sticky: StickyModelState
    }

    /// `defaults` nil keeps everything in memory (tests, previews).
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.stateKey), let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            drafts = p.drafts
            sticky = p.sticky
        }
        if let data = defaults?.data(forKey: Self.favoritesKey), let f = try? JSONDecoder().decode([ModelFavorite].self, from: data) {
            favorites = f
        }
    }

    // ponytail: writes the whole state on every pick (a few KB); T3 debounces 300ms, debounce if drafts grow large
    private func save() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(Persisted(drafts: drafts, sticky: sticky)) { defaults.set(data, forKey: Self.stateKey) }
    }

    // MARK: Favorites

    public func isFavorite(_ instance: ProviderInstanceId, _ model: String) -> Bool {
        favorites.contains { $0.provider == instance && $0.model == model }
    }

    /// Adds or removes one favorite and writes the whole array, like `updateSettings({favorites})`.
    public func toggleFavorite(_ instance: ProviderInstanceId, _ model: String) {
        if let i = favorites.firstIndex(where: { $0.provider == instance && $0.model == model }) {
            favorites.remove(at: i)
        } else {
            favorites.append(ModelFavorite(provider: instance, model: model))
        }
        if let defaults, let data = try? JSONEncoder().encode(favorites) { defaults.set(data, forKey: Self.favoritesKey) }
    }

    // MARK: Resolution

    /// Section 5.3: draft, then thread, then project default, then (new drafts) sticky and server
    /// defaults, then the instance default.
    public func resolve(_ key: String, _ ctx: ComposerSelectionContext) -> ResolvedComposerSelection {
        let draft = drafts[key] ?? ComposerModelDraft()
        let thread = ctx.thread
        let isNew = thread == nil
        var candidates: [ProviderInstanceId?] = [draft.activeInstance, thread?.providerInstanceId,
                                                 thread?.modelSelection.instanceId, ctx.projectDefaultModel?.instanceId]
        if isNew { candidates += [sticky.activeInstance, ctx.serverDefaults.defaultModelSelection?.instanceId] }
        let entry = ctx.catalog.resolveInstance(candidates)

        var slug: String?, options: [ProviderOptionSelection]?
        if let id = entry?.id {
            var sources: [InstanceModelSelection?] = [draft.selectionByInstance[id]]
            func from(_ s: ModelSelection?) -> InstanceModelSelection? {
                guard let s, s.instanceId == id else { return nil }
                let o = s.optionSelections
                return InstanceModelSelection(model: s.model, options: o.isEmpty ? nil : o)
            }
            sources += [from(thread?.modelSelection), from(ctx.projectDefaultModel)]
            if isNew { sources += [sticky.modelByInstance[id], from(ctx.serverDefaults.defaultModelSelection)] }
            let found = sources.compactMap { $0 }
            slug = found.first?.model ?? entry?.defaultModel
            // Options follow the same chain but only from sources naming this model.
            options = found.first { $0.model == slug && $0.options != nil }?.options
        }
        let model = slug.flatMap { entry?.model($0) }
        let descriptors = ModelTraits.descriptors(model, selections: options)
        let selection = entry.flatMap { e in slug.map { ModelSelection(instanceId: e.id, model: model?.slug ?? $0, selections: ModelTraits.dispatchOptions(model, options)) } }

        // Runtime mode (ChatView.tsx:2200-2208), shown filtered by the provider's supported modes.
        let modes = entry?.runtimeModes ?? RuntimeMode.all
        let wanted = draft.runtimeMode ?? thread.map { RuntimeMode(rawValue: $0.runtimeMode) }
            ?? ctx.projectDefaultRuntimeMode ?? ctx.serverDefaults.defaultRuntimeMode
        let shown = modes.contains(wanted) ? wanted : (modes.first ?? wanted)
        let persistMode = thread.flatMap { t in draft.runtimeMode.flatMap { $0.rawValue != t.runtimeMode ? $0 : nil } }

        let interaction: InteractionMode = ctx.planModeEnabled ? (draft.interactionMode ?? thread?.interactionMode ?? .default) : .default
        let persistInteraction = thread.flatMap { t in interaction != t.interactionMode ? interaction : nil }

        return ResolvedComposerSelection(entry: entry, instanceId: entry?.id, modelSlug: slug, model: model, options: options,
                                         descriptors: descriptors, modelSelection: selection, runtimeMode: shown,
                                         runtimeModeOptions: modes, runtimeModeToPersist: persistMode,
                                         interactionMode: interaction, interactionModeToPersist: persistInteraction)
    }

    // MARK: Picks

    /// `getStartedThreadModelChangeBlockReason`: the toast text when a started thread can't switch.
    public static func blockReason(from current: ResolvedComposerSelection, to instance: ProviderInstanceEntry, model: String,
                                   _ ctx: ComposerSelectionContext) -> String? {
        guard ctx.hasStartedSession, let currentEntry = current.entry else { return nil }
        if currentEntry.id != instance.id {
            return ctx.supportsProviderHandoff ? nil : "Start a new chat to switch providers"
        }
        if current.modelSlug != model,
           currentEntry.provider.requiresNewThreadForModelChange == true || instance.provider.requiresNewThreadForModelChange == true {
            return "Start a new chat to change models"
        }
        return nil
    }

    /// A model pick (`onProviderModelSelect`). Returns the block reason when the pick is refused.
    @discardableResult
    public func pickModel(_ key: String, instance: ProviderInstanceId, model slug: String, _ ctx: ComposerSelectionContext) -> String? {
        guard let entry = ctx.catalog.entry(instance), let model = entry.model(slug) else { return nil }
        if let reason = Self.blockReason(from: resolve(key, ctx), to: entry, model: model.slug, ctx) { return reason }
        // The new model starts from its remembered options, else its defaults.
        let selection = InstanceModelSelection(model: model.slug, options: sticky.optionsByModel[instance]?[model.slug])
        var draft = drafts[key] ?? ComposerModelDraft()
        draft.activeInstance = instance
        draft.selectionByInstance[instance] = selection
        draft.explicit = true
        drafts[key] = draft
        sticky.modelByInstance[instance] = selection
        sticky.activeInstance = instance
        save()
        return nil
    }

    /// A trait pick: `options` replace the current model's options (`setProviderModelOptions`, persistSticky).
    public func setOptions(_ key: String, _ options: [ProviderOptionSelection]?, _ ctx: ComposerSelectionContext) {
        let current = resolve(key, ctx)
        guard let id = current.instanceId, let slug = current.model?.slug ?? current.modelSlug else { return }
        let selection = InstanceModelSelection(model: slug, options: options)
        var draft = drafts[key] ?? ComposerModelDraft()
        draft.activeInstance = id
        draft.selectionByInstance[id] = selection
        draft.explicit = true
        drafts[key] = draft
        sticky.modelByInstance[id] = selection
        sticky.optionsByModel[id, default: [:]][slug] = options
        save()
    }

    /// An access pick. Persisted at the next send through `runtimeModeToPersist` or `launchThread.runtimeMode`.
    public func setRuntimeMode(_ key: String, _ mode: RuntimeMode) {
        drafts[key, default: ComposerModelDraft()].runtimeMode = mode
        save()
    }

    public func setInteractionMode(_ key: String, _ mode: InteractionMode) {
        drafts[key, default: ComposerModelDraft()].interactionMode = mode
        save()
    }

    /// After a successful send the thread carries the selection; drop the draft so the thread's
    /// values show again.
    public func didSend(_ key: String) {
        guard drafts.removeValue(forKey: key) != nil else { return }
        save()
    }

    /// Drops the picks of every key that matches, for a removed environment.
    public func removeDrafts(where matches: (String) -> Bool) {
        let before = drafts.count
        drafts = drafts.filter { !matches($0.key) }
        if drafts.count != before { save() }
    }

    /// A new-thread draft that became a server thread keeps its picks under the thread's key.
    public func moveDraft(from old: String, to new: String) {
        guard let d = drafts.removeValue(forKey: old) else { return }
        drafts[new] = d
        save()
    }
}
