import AppKit
import DesignSystem
import T3Protocol

/// IntegrationsSettings.tsx:1602-1638. Keep the existing row bindings and profile actions.
final class BrowserSettingsPage: ScopedSettingsPage {
    private let bindings: IntegrationsSettingsView
    private var desktopControls: [ControlView] = []
    private var profileList: BrowserProfileList?
    private var advanced: SettingsFoldedSectionView?

    init(context: SettingsPageContext) {
        bindings = IntegrationsSettingsView(context: context, groups: ["browser"])
        super.init(context: context)
        func take(_ id: String) -> SettingsRowView {
            let row = bindings.anchor(id) as! SettingsRowView
            anchors[id] = row
            return row
        }
        let access = take("agent-browser-access")
        let profiles = take("browser-profiles")
        anchors["browser-default-profile"] = profiles
        anchors["browser-manage-profiles"] = profiles
        profiles.detail = "Profiles separate cookies and logins. Incognito data is cleared when the app closes."
        (profiles.control as? ButtonView)?.title = "Add profile"
        let list = BrowserProfileList(context: context, bindings: bindings)
        profileList = list
        profiles.footer = list
        let links = take("browser-link-target")
        // This copy needs more space than the old fixed 160pt trigger.
        if let control = links.control {
            control.frame.size.width = 200
            links.control = control
        }
        let floating = take("browser-auto-show-floating-preview")
        let engine = take("browser-search-engine")
        let custom = (bindings.anchor("browser") as! SettingsSectionView).group.rows.compactMap { $0 as? SettingsRowView }.first { $0.title == "Custom search URL" }!
        let advancedRows = [take("browser-default-viewport"), take("browser-default-zoom"), take("browser-default-appearance")]
        let folded = SettingsFoldedSectionView(title: "Advanced", rows: advancedRows)
        advanced = folded
        folded.onToggle = { [weak self] in self?.onHeightChange?() }
        let recordings = [take("browser-recording-frame-rate"), take("browser-recording-key-presses"), take("browser-recording-mouse-presses")]
        var browsing: [any SettingsGroupRow] = [profiles, links, floating, engine, custom, folded]
        var recordingRows: [any SettingsGroupRow] = recordings
        if !context.desktopAvailable {
            browsing.insert(SettingsGroupNote("Only available in the desktop app.", size: 12), at: 0)
            recordingRows.insert(SettingsGroupNote("Only available in the desktop app.", size: 12), at: 0)
        }
        for row in [profiles, links, floating] + advancedRows + recordings {
            desktopControls += Self.controls(in: row)
        }
        // The original binder refreshes its group after hidden rows change. Its new owner keeps the rows.
        (bindings.anchor("browser") as? SettingsSectionView)?.group.rows = []
        body = [section("browser-agent-access", "Agent access", [access]), section("browser", "Browsing", browsing),
                section("browser-recordings", "Recordings", recordingRows)]
        refresh()
    }

    override func refresh() {
        bindings.refresh()
        super.refresh()
        if !context.desktopAvailable { desktopControls.forEach { $0.isEnabled = false } }
        profileList?.refresh()
    }

    override func anchor(_ id: String) -> NSView? {
        if ["browser-default-viewport", "browser-default-zoom", "browser-default-appearance"].contains(id) { advanced?.isOpen = true }
        return super.anchor(id)
    }

    private static func controls(in view: NSView) -> [ControlView] {
        (view as? ControlView).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
    }

    private final class BrowserProfileList: BoxView, SettingsGroupRow {
        private let context: SettingsPageContext
        private weak var bindings: IntegrationsSettingsView?
        private var rows: [NSView] = []
        init(context: SettingsPageContext, bindings: IntegrationsSettingsView) {
            self.context = context
            self.bindings = bindings
            super.init(frame: .zero)
            var style = BoxStyle()
            style.radius = 8
            style.border = Themed.color(\.border, 0.6)
            boxStyle = style
            refresh()
        }
        func refresh() {
            rows.forEach { $0.removeFromSuperview() }
            rows = BrowserProfiles.resolved(context.client).filter { $0["id"]?.stringValue != "incognito" }.map { profile in
                let row = DSView()
                let name = profile["name"]?.stringValue ?? "Profile"
                let label = LabelView(name, font: DSFont.ui(14))
                label.lineHeight = 20
                label.frame = NSRect(x: 12, y: 12, width: ceil(label.textWidth), height: 20)
                label.alphaValue = context.desktopAvailable ? 1 : 0.64
                row.addSubview(label)
                if profile["id"]?.stringValue == BrowserProfiles.defaultId(context.client) {
                    let badge = BadgeView("Default")
                    badge.frame = NSRect(origin: NSPoint(x: label.frame.maxX + 8, y: 12), size: badge.intrinsicContentSize)
                    badge.alphaValue = context.desktopAvailable ? 1 : 0.64
                    row.addSubview(badge)
                }
                let menu = ButtonView(nil, icon: .moreVertical, variant: .ghostMuted, size: .iconXs).menuTrigger()
                menu.isEnabled = context.desktopAvailable
                menu.setAccessibilityLabel(name + " options")
                menu.frame = NSRect(x: max(0, bounds.width - 36), y: 10, width: 24, height: 24)
                menu.action = { [weak self, weak menu] in
                    guard let self, let menu else { return }
                    var makeDefault = MenuItem("Use as default")
                    makeDefault.action = { [weak self] in self?.context.writeClient?(["browserDefaultProfileId": profile["id"] ?? .string("default")]) }
                    var clear = MenuItem("Clear browsing data")
                    clear.action = { [weak self] in self?.bindings?.clearBrowserProfile(profile, remove: false) }
                    var choices = [makeDefault, clear]
                    if profile["id"]?.stringValue != "default" {
                        var rename = MenuItem("Rename")
                        rename.action = { [weak self] in self?.bindings?.editBrowserProfile(profile) }
                        var remove = MenuItem("Remove")
                        remove.action = { [weak self] in self?.bindings?.clearBrowserProfile(profile, remove: true) }
                        choices += [rename, remove]
                    }
                    MenuPopupView.show(choices, from: menu, placement: .dropdown)
                }
                row.addSubview(menu)
                addSubview(row)
                return row
            }
            needsLayout = true
        }
        func height(forWidth width: CGFloat) -> CGFloat { 2 + CGFloat(rows.count) * 44 + 8 }
        override func layout() {
            super.layout()
            for (i, row) in rows.enumerated() {
                row.frame = NSRect(x: 1, y: 1 + CGFloat(i) * 44, width: bounds.width - 2, height: 44)
                row.subviews.compactMap { $0 as? ButtonView }.first?.frame.origin.x = max(0, row.bounds.width - 36)
            }
        }
    }
}
