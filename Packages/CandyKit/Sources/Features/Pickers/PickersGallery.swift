import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Sample providers shaped like the recorded sandbox config (fixtures/transcripts/01-basic.jsonl):
/// Codex not ready, Claude ready with its current and a few legacy models.
@MainActor
public enum PickersPreview {
    static func effort(_ choices: [(String, String)], default def: String, ultrathink: Bool = true) -> ProviderOptionDescriptor {
        ProviderOptionDescriptor(id: "effort", label: "Reasoning", type: .select,
                                 options: choices.map { ProviderOptionChoice(id: $0.0, label: $0.1, isDefault: $0.0 == def ? true : nil) },
                                 promptInjectedValues: ultrathink ? ["ultrathink"] : nil)
    }

    static let levels = [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra High"), ("max", "Max"), ("ultrathink", "Ultrathink")]
    static let fast = ProviderOptionDescriptor(id: "fastMode", label: "Fast Mode", type: .boolean)

    public static var providers: [ServerProvider] {
        var codex = ServerProvider(instanceId: "codex", driver: "codex", displayName: "Codex", installed: false, status: .error)
        codex.message = "Could not start Codex CLI (`codex`)."
        let claude = ServerProvider(instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude", models: [
            ServerProviderModel(slug: "claude-opus-5-5", name: "Claude Opus 5.5", badge: "new", optionDescriptors: [effort(levels, default: "medium"), fast]),
            ServerProviderModel(slug: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", badge: "new", optionDescriptors: [effort(levels, default: "high")]),
            ServerProviderModel(slug: "claude-fable-5-1", name: "Claude Fable 5.1", isDefault: true, optionDescriptors: [effort(levels, default: "medium")]),
            ServerProviderModel(slug: "claude-haiku-5-5", name: "Claude Haiku 5.5", badge: "new", optionDescriptors: [effort(levels, default: "medium")]),
            ServerProviderModel(slug: "claude-opus-4-6", name: "Claude Opus 4.6", isLegacy: true, optionDescriptors: [
                effort(levels.filter { $0.0 != "xhigh" }, default: "high"), fast,
                ProviderOptionDescriptor(id: "contextWindow", label: "Context Window", type: .select,
                                         options: [ProviderOptionChoice(id: "200k", label: "200k"), ProviderOptionChoice(id: "1m", label: "1M", isDefault: true)])]),
            ServerProviderModel(slug: "claude-haiku-4-5", name: "Claude Haiku 4.5", isLegacy: true,
                                optionDescriptors: [ProviderOptionDescriptor(id: "thinking", label: "Thinking", type: .boolean)]),
        ])
        return [codex, claude]
    }

    /// Pickers for a draft with Claude Haiku 5.5 picked, kept in memory.
    public static func pickers(model: String = "claude-haiku-5-5") -> ComposerPickers {
        let ctx = ComposerSelectionContext(catalog: ProviderCatalog(providers))
        let store = ComposerSelectionStore(defaults: nil)
        store.pickModel("preview", instance: "claudeAgent", model: model, ctx)
        return ComposerPickers(store: store, draftKey: "preview", context: ctx)
    }
}

/// Gallery sections: the footer controls in their states and the three popups shown open.
@MainActor
public enum PickersGallery {
    public static var sections: [ComponentGallery.Section] {
        [
            ComponentGallery.Section(title: "Composer footer controls", height: 120) {
                let v = DSView(frame: NSRect(x: 0, y: 0, width: 518, height: 120))
                for (i, model) in ["claude-haiku-5-5", "claude-opus-4-6", "claude-haiku-4-5"].enumerated() {
                    let p = PickersPreview.pickers(model: model)
                    if i == 1 { p.traitsButton.isPopupOpen = true }
                    if i == 2 { p.accessButton.isPopupOpen = true }
                    p.controlsView.frame = NSRect(x: 8, y: 8 + CGFloat(i) * 36, width: p.controlsView.intrinsicContentSize.width, height: 28)
                    v.addSubview(p.controlsView)
                }
                return v
            },
            ComponentGallery.Section(title: "Model picker", height: 320) {
                let view = ModelPickerView(catalog: ProviderCatalog(PickersPreview.providers), favorites: [], active: "claudeAgent",
                                           activeModel: "claude-haiku-5-5")
                let popup = PickerPopupView(view)
                return framed(popup)
            },
            ComponentGallery.Section(title: "Model picker (search)", height: 330) {
                let view = ModelPickerView(catalog: ProviderCatalog(PickersPreview.providers),
                                           favorites: [ModelFavorite(provider: "claudeAgent", model: "claude-opus-5-5")],
                                           active: "claudeAgent", activeModel: "claude-haiku-5-5")
                view.setQuery("opus")
                return framed(PickerPopupView(view))
            },
            ComponentGallery.Section(title: "Traits menu and access select", height: 440) {
                let v = DSView(frame: NSRect(x: 0, y: 0, width: 600, height: 440))
                let p = PickersPreview.pickers(model: "claude-opus-4-6")
                let traits = PickerPopupView(PickerMenuView(entries: p.traitsEntries(), style: .menu, minimumWidth: 158))
                traits.frame = NSRect(origin: CGPoint(x: 8, y: 8), size: traits.popupSize)
                let access = PickerPopupView(PickerMenuView(entries: p.accessEntries(), style: .select, minimumWidth: 264))
                access.frame = NSRect(origin: CGPoint(x: 16 + traits.popupSize.width, y: 8), size: access.popupSize)
                v.addSubview(traits)
                v.addSubview(access)
                return v
            },
        ]
    }

    private static func framed(_ popup: PickerPopupView) -> NSView {
        let v = DSView(frame: NSRect(x: 0, y: 0, width: popup.popupSize.width + 16, height: popup.popupSize.height + 16))
        popup.frame = NSRect(origin: CGPoint(x: 8, y: 8), size: popup.popupSize)
        v.addSubview(popup)
        return v
    }
}
