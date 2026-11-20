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

/// The Experimental tab: every experimental switch of CandyWrapper's own, one row each. Redesign has its own tab. T3's own betas
/// (Working section, Compact idle Claude threads, Review guides) stay on the pages T3 puts them on.
public final class ExperimentalSettingsView: SettingsPageBase {
    /// Add a feature here, one entry each.
    public static let toggles: [ExperimentalToggle] = [
        ExperimentalToggle(title: "Tabs", detail: "A tab strip at the top of the window for open threads and other pages. Cmd-click a thread to open it in a new tab.", needsRedesign: true, isOn: { ThreadTabsSetting.isOn }, set: { ThreadTabsSetting.set($0) }, observe: { ThreadTabsSetting.observe($0) }),
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
