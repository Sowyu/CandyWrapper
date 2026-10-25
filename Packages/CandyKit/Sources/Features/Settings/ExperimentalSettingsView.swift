import AppKit
import DesignSystem

/// One of CandyWrapper's own experimental features. Each keeps its switch in its own store, under the key it always had.
@MainActor
public struct ExperimentalToggle {
    public let title: String
    public let detail: String
    /// Works only in Redesign: while Redesign is off the switch is disabled and says so.
    public var needsRedesign = false
    public let isOn: () -> Bool
    public let set: (Bool) -> Void
    /// Calls back when the stored value changes elsewhere, such as a sync from another device. Returns the unsubscribe.
    public let observe: (@escaping @MainActor () -> Void) -> () -> Void
}

/// The Experimental tab: every experimental switch of CandyWrapper's own, one row each. T3's own betas
/// (Working section, Compact idle Claude threads, Review guides) stay on the pages T3 puts them on.
public final class ExperimentalSettingsView: SettingsPageBase {
    /// Add a feature here, one entry each.
    public static let toggles: [ExperimentalToggle] = [
        ExperimentalToggle(title: "Redesign", detail: "CandyWrapper's own look, with a picture behind the chat. Off goes back to the theme you had before.", isOn: { ThemeLibrary.shared.isRedesignOn }, set: { ThemeLibrary.shared.setRedesign($0) }, observe: { f in let id = ThemeLibrary.shared.observe(f); return { ThemeLibrary.shared.removeObserver(id) } }),
        ExperimentalToggle(title: "Orchestrator", detail: "One thread that manages every thread on its machine. It adds a pinned row to the sidebar, its own chat and an Orchestrator tab here in Settings.", needsRedesign: true, isOn: { OrchestratorStore.shared.config.enabled }, set: { on in OrchestratorStore.shared.update { $0.enabled = on } }, observe: { f in let id = OrchestratorStore.shared.observe(f); return { OrchestratorStore.shared.removeObserver(id) } }),
    ]

    private var unsubscribe: [() -> Void] = []

    public override init(context: SettingsPageContext) {
        super.init(context: context)
        let rows = Self.toggles.map { toggle in
            let sw = SwitchView(isOn: toggle.isOn())
            sw.setAccessibilityLabel(toggle.title)
            sw.onChange = { on in toggle.set(on) }
            let r = row(nil, title: toggle.title, detail: toggle.detail, control: sw)
            binder.add { [weak sw, weak r] in
                sw?.isOn = toggle.isOn()
                let blocked = toggle.needsRedesign && !ThemeLibrary.shared.isRedesignOn
                sw?.isEnabled = !blocked
                r?.detail = blocked ? "\(toggle.detail) Needs Redesign." : toggle.detail
            }
            unsubscribe.append(toggle.observe { [weak self] in self?.refresh() })
            return r
        }
        items = [section(nil, "Features", rows)]
        binder.refresh()
    }

    isolated deinit { unsubscribe.forEach { $0() } }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
