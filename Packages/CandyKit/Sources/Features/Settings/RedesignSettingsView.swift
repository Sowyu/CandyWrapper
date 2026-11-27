import AppKit
import DesignSystem
import T3Protocol

/// What Redesign's model picker shows, from the client settings on this device (the user, 2026-11-21).
@MainActor
enum RedesignPickerSettings {
    /// One column: tabs, search, the list (six rows, then it scrolls), Reasoning and the footer. Off, the default since
    /// 2026-11-21, shows the rail and the list with a details pane at their right.
    static var stacked: Bool { stackedOverride ?? ClientSettingsStore.shared.current.bool("redesignStackedPicker") }
    /// Tests set the two switches per task, so suites running side by side don't share them.
    @TaskLocal nonisolated static var stackedOverride: Bool?
    @TaskLocal nonisolated static var accountOverride: Bool?
    /// The provider's account card at the top of the details pane, or between the search and the list when stacked. Off,
    /// the tabs keep T3's status tooltip.
    static var showsAccount: Bool { accountOverride ?? ClientSettingsStore.shared.current.bool("redesignPickerAccount") }
    /// The details pane's width the reader dragged, or nil for the default.
    static var paneWidth: CGFloat? {
        get { ClientSettingsStore.shared.current["redesignPickerPaneWidth"].doubleValue.map { CGFloat($0) } }
        set { ClientSettingsStore.shared.update(["redesignPickerPaneWidth": newValue.map { .number(Double($0)) } ?? .null]) }
    }
}

/// The Redesign tab, CandyWrapper's own: the switch that turns Redesign on, then every setting only Redesign uses.
/// The switch is the theme picker's own setting, so the two always agree. While Redesign is off the rows under it
/// stay visible and inert.
public final class RedesignSettingsView: SettingsPageBase {
    static let offReason = "Turn on Redesign to change this."
    private let library: ThemeLibrary
    private var themeObserver: Int?
    /// The master switch, bound to the theme picker's setting.
    let master: SwitchView
    /// Where Redesign shows: both appearances, or one, with the theme from Settings > Appearance in the other.
    let useIn = settingsSelect(RedesignSettingsView.useInChoices.map(\.0), width: 136)
    static let useInChoices: [(String, Set<ThemeAppearance>)] = [("Light and dark", [.light, .dark]), ("Dark only", [.dark]), ("Light only", [.light])]
    /// The rows inert while Redesign is off: all but the switch.
    private(set) var gated: [SettingsRowView] = []

    public convenience override init(context: SettingsPageContext) { self.init(context: context, library: .shared) }

    init(context: SettingsPageContext, library: ThemeLibrary) {
        self.library = library
        master = SwitchView(isOn: library.isRedesignOn)
        super.init(context: context)
        master.setAccessibilityLabel("Redesign")
        master.onChange = { on in library.setRedesign(on) }
        // The old theme card could pick Redesign for one appearance; "Use in" keeps that.
        useIn.setAccessibilityLabel("Use Redesign in")
        useIn.onChange = { index in library.setRedesignUseIn(Self.useInChoices[index].1) }
        let masterRow = row("redesign", title: "Redesign",
                            detail: "CandyWrapper's own look, which hands back your previous theme when you turn it off.",
                            control: SettingsControlGroup([useIn, master], gap: 12))
        binder.add { [weak self, weak master] in
            master?.isOn = library.isRedesignOn
            let shown = library.isRedesignOn ? library.redesignAppearances : library.redesignUseIn
            if let i = Self.useInChoices.firstIndex(where: { $0.1 == shown }), self?.useIn.selectedIndex != i { self?.useIn.selectedIndex = i }
        }

        let reading = readingWidthRow()
        // Capy's dither moves (the user, 2026-11-21: "capys plain dither isnt just static"). Gradient is the only
        // background (the user, 2026-11-27: "lets just only do the gradient theme"), so this is its one setting.
        let animate = clientSwitch("redesign-gradient-animate", "Let the dots at the top of a new thread drift, except while the window is in the background or Reduce Motion is on.",
                                   key: "redesignGradientAnimate", reset: "animate background", title: "Animate background")
        let look: [SettingsRowView] = [accentRow(), animate, avatarsRow(), reading]
        let stacked = clientSwitch("redesign-stacked-picker", "Show the models in one column instead of beside a details pane.",
                                   key: "redesignStackedPicker", reset: "stacked model picker", title: "Stacked model picker")
        let account = clientSwitch("redesign-picker-account", "Show the provider's account and usage bar in the model picker.",
                                   key: "redesignPickerAccount", reset: "account and limits", title: "Account and limits in the model picker")
        let rows = sidebarRowsRow()
        // Capy's layout (the user, 2026-11-21: "also make it a toggle").
        let inset = clientSwitch("redesign-inset-panel", "Show the thread as a rounded card inset from the window instead of running it to the window's edges.",
                                 key: "redesignInsetPanel", reset: "inset panel", title: "Inset panel")
        // The user, 2026-11-26: the quiet Compact toggle by default, the old split button kept under Legacy.
        let legacyCompact = clientSwitch("redesign-legacy-compact-send", "Brings back the wide Compact and send button, with a menu to send with full history, in place of the Compact toggle.",
                                         key: "redesignLegacyCompactSend", reset: "compact and send button", title: "Compact and send button")
        gated = look + [inset, rows, stacked, account, legacyCompact]
        binder.add { [weak self] in
            guard let self else { return }
            let off = library.isRedesignOn ? nil : Self.offReason
            for r in self.gated where r.inertReason != off { r.inertReason = off }
            // "Use in" means nothing until Redesign is on.
            if self.useIn.isHidden == library.isRedesignOn { self.useIn.isHidden = !library.isRedesignOn; masterRow.needsLayout = true }
            let readingOff = off ?? Self.readingWidthReason(self.client.string("chatWidth"))
            if reading.inertReason != readingOff { reading.inertReason = readingOff }
        }
        // Most used first: the switch, the colors and motion, the layout, the sidebar, then the model picker's options.
        items = [
            section(nil, "Theme", [masterRow]),
            section("redesign-look", "Look", look),
            section("redesign-layout", "Layout", [inset]),
            section("redesign-sidebar", "Sidebar", [rows]),
            section("redesign-model-picker", "Model picker", [stacked, account]),
            section("redesign-legacy", "Legacy", [legacyCompact]),
        ]
        themeObserver = library.observe { [weak self] in self?.refresh() }
        binder.refresh()
    }

    isolated deinit { themeObserver.map { library.removeObserver($0) } }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The sidebar's thread rows: two lines with the environment and provider under the title (the default, the user,
    /// 2026-11-26: "keep 2 lines default"), or one line after Capy.
    private func sidebarRowsRow() -> SettingsRowView {
        let key = "redesignSidebarRows", values = ["two", "one"]
        let toggle = ToggleGroupView(variant: .segmented, items: [("Two lines", nil), ("One line", nil)], selected: 0)
        toggle.setAccessibilityLabel("Sidebar rows")
        let r = row("redesign-sidebar-rows", title: "Sidebar rows",
                    detail: "Show each thread's environment and provider on a second line, or keep each thread to one line.",
                    control: toggle)
        toggle.onChange = { [weak self, weak toggle] i in
            guard let self else { return }
            guard let i else { toggle?.selectedIndex = values.firstIndex(of: self.client.string(key)) ?? 0; return }
            self.context.writeClient?([key: .string(values[i])])
        }
        binder.add { [weak self, weak toggle] in
            guard let self else { return }
            toggle?.selectedIndex = values.firstIndex(of: self.client.string(key)) ?? 0
        }
        return r
    }

    /// Generated project and account avatars: pixel sprites (the user, 2026-11-21: "i like c4"), or T3's letters.
    private func avatarsRow() -> SettingsRowView {
        let key = "redesignProjectAvatars", values = ["sprites", "letters"]
        let toggle = ToggleGroupView(variant: .segmented, items: [("Sprites", nil), ("Letters", nil)], selected: 0)
        toggle.setAccessibilityLabel("Project avatars")
        let r = row("redesign-project-avatars", title: "Project avatars",
                    detail: "What a project or account without its own picture shows: a pixel sprite, or its initials.", control: toggle)
        toggle.onChange = { [weak self, weak toggle] i in
            guard let self else { return }
            guard let i else { toggle?.selectedIndex = values.firstIndex(of: self.client.string(key)) ?? 0; return }
            self.context.writeClient?([key: .string(values[i])])
        }
        binder.add { [weak self, weak toggle] in
            guard let self else { return }
            toggle?.selectedIndex = values.firstIndex(of: self.client.string(key)) ?? 0
        }
        return r
    }

    /// The thread column's maximum under Comfortable (the user, 2026-11-22: "make it adjustable actually"). It writes on
    /// every step: the thread moves its composer and the art's column at once and lays its rows out a moment later.
    private func readingWidthRow() -> SettingsRowView {
        let key = "redesignReadingWidth"
        let control = SettingsSliderControl(value: Double(ThreadChatWidth.readingDefault), range: ThreadChatWidth.readingRange, step: 20, outputWidth: 64)
        control.format = { "\(Int($0)) pt" }
        control.slider.setAccessibilityLabel("Reading width")
        let hint = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        let r = row("redesign-reading-width", title: "Reading width", detail: "How wide a thread\u{2019}s text and the composer can grow.",
                    control: SettingsControlGroup([hint, control], gap: 12))
        let slot = ResetSlot(label: "reading width")
        r.accessories = [slot]
        slot.action = { [weak self] in self?.context.writeClient?([key: ClientSettings.fields[key]!.defaultValue]) }
        control.onChange = { [weak self] v in self?.context.writeClient?([key: .number(v.rounded())]) }
        binder.add { [weak self, weak control, weak hint] in
            guard let self else { return }
            let width = Double(self.client.int(key))
            if control?.value != width { control?.value = width }
            let text = "about \(Self.charactersPerLine(CGFloat(width))) characters a line"
            if hint?.text != text { hint?.text = text; hint?.superview?.invalidateIntrinsicContentSize(); hint?.superview?.needsLayout = true }
            slot.isShown = !self.client.isDefault(key)
        }
        return r
    }

    /// Why Reading width does nothing: Wide and Full keep T3's widths.
    static func readingWidthReason(_ chatWidth: String) -> String? {
        switch chatWidth { case "wide": "Chat width is set to Wide in Appearance."; case "full": "Chat width is set to Full in Appearance."; default: nil }
    }

    /// Roughly how many characters of a reply's body text fit in `width`, from the body font's average advance over
    /// lowercase prose, rounded to 5. It follows the interface text size.
    static func charactersPerLine(_ width: CGFloat) -> Int {
        let sample = "the quick brown fox jumps over the lazy dog while five wizards box"
        let advance = (sample as NSString).size(withAttributes: [.font: MarkdownStyle.font(MarkdownStyle.fontSize)]).width / CGFloat(sample.count)
        return Int((width / max(1, advance) / 5).rounded()) * 5
    }

    /// Redesign's accent (the user, 2026-10-23). It recolors the palette's accent roles.
    private func accentRow() -> SettingsRowView {
        let key = "ditherAccent"
        let swatches = DitherAccent.all.map { accent in
            let b = AccentSwatchButton(accent)
            b.action = { [weak self] in self?.context.writeClient?([key: .string(accent.id)]) }
            return b
        }
        let r = row("accent-color", title: "Accent color", detail: "The color of switches, the send button, focus and selection.",
                    control: SettingsControlGroup(swatches, gap: 6))
        let slot = ResetSlot(label: "accent color")
        r.accessories = [slot]
        slot.action = { [weak self] in self?.context.writeClient?([key: ClientSettings.fields[key]!.defaultValue]) }
        binder.add { [weak self] in
            guard let self else { return }
            let current = DitherAccent.named(self.client.string(key)).id
            for b in swatches { b.isSelected = b.accent.id == current }
            slot.isShown = !self.client.isDefault(key)
        }
        return r
    }
}

/// One accent in the Accent color row: a 16pt dot, ringed in the foreground color when chosen.
final class AccentSwatchButton: ControlView {
    let accent: DitherAccent
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; setAccessibilityValue(isSelected) } } }

    init(_ accent: DitherAccent) {
        self.accent = accent
        super.init(frame: .zero)
        scalesWhenPressed = false
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(accent.label)
        setTooltip(accent.label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
    override var wantsUpdateLayer: Bool { false }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: bounds.midX - 11, y: bounds.midY - 11, width: 22, height: 22)
        if isSelected || state.focusVisible {
            Themed.color(\.foreground, isSelected ? 0.9 : 0.5).setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let dark = effectiveAppearance.isDark
        (state.hovered && !isSelected ? DitherAccent.color(DitherAccent.mix(accent.accent(dark: dark), white: 0.12))
            : DitherAccent.color(accent.accent(dark: dark))).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3)).fill()
    }
}
