import AppKit
import DesignSystem
import T3Protocol

/// `BackgroundActivityAdvancedDialog` (SettingsPanels.tsx:875-1150): the shared policy, four intervals
/// in seconds and four pause switches, in one bordered card. Every change writes the whole custom
/// `backgroundActivity` (`backgroundActivityOverrideSettings`); Reset all goes back to Balanced.
@MainActor
enum BackgroundActivityDialog {
    static func make(context: SettingsPageContext) -> DialogView {
        let dialog = DialogView(kind: .dialog, title: "Background Activity",
                                message: "Tune the shared power policy and the background intervals that feed it.")
        dialog.maxWidth = 576
        let card = Card(context: context)
        dialog.panelContent = [card]
        let reset = ButtonView("Reset all", variant: .outline)
        let done = ButtonView("Done")
        reset.action = { context.patchServer(["backgroundActivity": BackgroundActivity.defaultSettings]) }
        done.action = { [weak dialog] in dialog?.onClose?() }
        dialog.footerButtons = [reset, done]
        context.observe { [weak card] in card?.refresh() }
        return dialog
    }

    /// The `fieldset` card (`rounded-xl border bg-card`): rows `px-4 py-3` divided by borders, then a 2-column switch grid.
    final class Card: DSView {
        private let context: SettingsPageContext
        private var rows: [(title: LabelView, detail: TextBlockView, control: NSView)] = []
        private var toggles: [(label: LabelView, sw: SwitchView, key: String)] = []
        private let policy = settingsSelect(["Balanced", "Performance", "Battery saver"], width: 160)
        private var fields: [(field: NumberFieldView, key: String, minimum: Double)] = []
        private var dividers: [CALayer] = []

        init(context: SettingsPageContext) {
            self.context = context
            super.init(frame: .zero)
            layer?.cornerRadius = 12
            layer?.borderWidth = 1
            layer?.masksToBounds = true
            policy.setAccessibilityLabel("Shared background policy")
            policy.onChange = { [weak self] i in
                guard let self else { return }
                self.context.patchServer(["backgroundActivity": BackgroundActivity.sharedPolicySettings(self.context.scope.values,
                                                                                                         profile: BackgroundActivity.profiles[i])])
            }
            addRow("Shared policy", "Controls whether background work may run after a subscribed interval fires.", policy)
            interval(SettingsSearch.title("git-fetch-interval"), "Refresh remote branch status in the background.", key: "automaticGitFetchInterval",
                     minimum: 0, step: 5, label: "Git fetch interval")
            interval("Provider health interval", "Refresh provider availability, versions, auth state, and model metadata.",
                     key: "providerHealthRefreshInterval", minimum: 0, step: 30, label: "Provider health interval")
            interval("Host power monitor", "Poll host power state while clients are active.", key: "hostPowerMonitorActiveInterval",
                     minimum: 5, step: 5, label: "Active host power interval")
            interval("Idle host monitor", "Poll host power state when no foreground client is active.", key: "hostPowerMonitorIdleInterval",
                     minimum: 5, step: 30, label: "Idle host power interval")
            for (key, label) in [("pauseWhenHostLocked", "Pause when host is locked"), ("pauseWhenHostLowPower", "Pause on host low power"),
                                 ("pauseWhenClientLowPower", "Pause on client low power"), ("pauseWhenOnBattery", "Pause on battery")] {
                let l = LabelView(label, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.cardForeground))
                l.lineHeight = 20
                let sw = SwitchView(isOn: false)
                sw.setAccessibilityLabel(label)
                sw.onChange = { [weak self] on in
                    guard let self else { return }
                    self.context.patchServer(["backgroundActivity": BackgroundActivity.overrideSettings(self.context.scope.values, [key: .bool(on)])])
                }
                addSubview(l); addSubview(sw)
                toggles.append((l, sw, key))
            }
            for _ in 0..<7 {
                let d = CALayer()
                d.actions = ["position": NSNull(), "bounds": NSNull()]
                layer?.addSublayer(d)
                dividers.append(d)
            }
            refresh()
        }

        private func addRow(_ title: String, _ detail: String, _ control: NSView) {
            let t = LabelView(title, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.cardForeground))
            t.lineHeight = 20
            let d = TextBlockView()
            d.text = detail
            d.font = DSFont.ui(12)
            d.lineHeight = 19.5
            d.color = Themed.color(\.mutedForeground)
            [t, d, control].forEach(addSubview)
            rows.append((t, d, control))
        }

        private func interval(_ title: String, _ detail: String, key: String, minimum: Double, step: Double, label: String) {
            let field = NumberFieldView(value: 0, size: .sm)
            field.step = step
            field.range = minimum ... .infinity
            field.frame.size = NSSize(width: 128, height: 28)
            field.setAccessibilityLabel("\(label) in seconds")
            field.onChange = { [weak self] value in
                guard let self else { return }
                let seconds = BackgroundActivity.normalizeIntervalSeconds(value, minimum: minimum)
                self.context.patchServer(["backgroundActivity": BackgroundActivity.overrideSettings(self.context.scope.values, [key: .number(seconds * 1000)])])
            }
            let unit = LabelView("seconds", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            unit.lineHeight = 16
            unit.frame.size = NSSize(width: ceil(unit.textWidth) + 1, height: 16)
            addRow(title, detail, SettingsControlGroup([field, unit]))
            fields.append((field, key, minimum))
        }

        func refresh() {
            let r = BackgroundActivity.resolveServer(context.scope.values)
            policy.selectedIndex = BackgroundActivity.profiles.firstIndex(of: r.profile)
            let ms: [String: Double] = ["automaticGitFetchInterval": r.automaticGitFetchInterval, "providerHealthRefreshInterval": r.providerHealthRefreshInterval,
                                        "hostPowerMonitorActiveInterval": r.hostPowerMonitorActiveInterval, "hostPowerMonitorIdleInterval": r.hostPowerMonitorIdleInterval]
            for f in fields { f.field.value = ((ms[f.key] ?? 0) / 1000).rounded() }
            let flags: [String: Bool] = ["pauseWhenHostLocked": r.pauseWhenHostLocked, "pauseWhenHostLowPower": r.pauseWhenHostLowPower,
                                         "pauseWhenClientLowPower": r.pauseWhenClientLowPower, "pauseWhenOnBattery": r.pauseWhenOnBattery]
            for t in toggles { t.sw.isOn = flags[t.key] ?? false }
            needsDisplay = true
        }

        private func rowHeight(_ width: CGFloat, _ i: Int) -> CGFloat {
            let textWidth = width - 32 - 32 - (i == 0 ? 160 : 128 + 8 + 50)
            return 12 + max(20 + 4 + rows[i].detail.height(forWidth: max(80, textWidth)), 28) + 12
        }

        override var intrinsicContentSize: NSSize {
            let w = bounds.width > 0 ? bounds.width : 528
            return NSSize(width: NSView.noIntrinsicMetric, height: rows.indices.reduce(0) { $0 + rowHeight(w, $1) } + CGFloat(rows.count) + 89)
        }

        override func updateLayer() {
            layer?.borderColor = Themed.color(\.border).cgColor(in: self)
            layer?.backgroundColor = Themed.color(\.card).cgColor(in: self)
            for d in dividers { d.backgroundColor = Themed.color(\.border).cgColor(in: self) }
        }

        override func layout() {
            super.layout()
            let w = bounds.width
            var y: CGFloat = 0
            var di = 0
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (i, row) in rows.enumerated() {
                let h = rowHeight(w, i)
                let cs = (row.control as? SettingsControlGroup)?.intrinsicContentSize ?? NSSize(width: 160, height: 28)
                let textWidth = w - 32 - 32 - cs.width
                let th = 20 + 4 + row.detail.height(forWidth: max(80, textWidth))
                let ty = y + (h - th) / 2
                row.title.frame = NSRect(x: 16, y: ty, width: textWidth, height: 20)
                row.detail.frame = NSRect(x: 16, y: ty + 24, width: textWidth, height: th - 24)
                row.control.frame = NSRect(x: w - 16 - cs.width, y: y + (h - cs.height) / 2, width: cs.width, height: cs.height)
                y += h
                dividers[di].frame = CGRect(x: 0, y: y, width: w, height: 1); di += 1
                y += 1
            }
            // The switch grid: two columns, `border-r` between, `border-b` between the two rows.
            let colW = (w - 1) / 2
            for (i, t) in toggles.enumerated() {
                let col = CGFloat(i % 2), rowY = y + CGFloat(i / 2) * 45
                let x = col * (colW + 1)
                t.label.frame = NSRect(x: x + 16, y: rowY + 12, width: colW - 32 - 30, height: 20)
                t.sw.frame = NSRect(x: x + colW - 16 - 30, y: rowY + 12 + 1, width: 30, height: 18)
            }
            if dividers.count > di { dividers[di].frame = CGRect(x: 0, y: y + 44, width: w, height: 1); di += 1 }
            if dividers.count > di { dividers[di].frame = CGRect(x: colW, y: y, width: 1, height: 89) }
            CATransaction.commit()
        }
    }
}
