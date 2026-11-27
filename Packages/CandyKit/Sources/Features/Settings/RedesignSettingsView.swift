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
/// stay visible and inert, except Ignore Reduce Transparency.
public final class RedesignSettingsView: SettingsPageBase {
    static let offReason = "Turn on Redesign to change this."
    private let library: ThemeLibrary
    private var themeObserver: Int?
    /// The master switch, bound to the theme picker's setting.
    let master: SwitchView
    /// Where Redesign shows: both appearances, or one, with the theme from Settings > Appearance in the other.
    let useIn = settingsSelect(RedesignSettingsView.useInChoices.map(\.0), width: 136)
    static let useInChoices: [(String, Set<ThemeAppearance>)] = [("Light and dark", [.light, .dark]), ("Dark only", [.dark]), ("Light only", [.light])]
    /// The rows inert while Redesign is off: all but the switch and Ignore Reduce Transparency.
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

        let picture = pictureRow(), dim = textDimRow(), reading = readingWidthRow()
        // Capy's no-picture dither moves (the user, 2026-11-21: "capys plain dither isnt just static").
        let animate = clientSwitch("redesign-gradient-animate", "Let Flower's lotus bloom and its dots drift, except while the window is in the background or Reduce Motion is on.",
                                   key: "redesignGradientAnimate", reset: "animate background", title: "Animate background")
        let tint = clientSwitch("redesign-tint", "Lean the window's surfaces a little toward the picture's color.",
                                key: "redesignTintFromPicture", reset: "tint from picture", title: "Tint from picture")
        let ink = inkRow(), dots = dotSizeRow(), threadFlower = threadFlowerRow()
        // Background first, then only the rows the chosen background uses; the binder below hides the rest.
        let background: [SettingsRowView] = [backgroundRow(), picture, ink, dots, tint, animate, threadFlower, dim]
        let look: [SettingsRowView] = [accentRow(), avatarsRow(), reading]
        let transparency = clientSwitch("ignore-reduce-transparency", "Show the picture and blur as if Reduce Transparency were off in macOS.",
                                        key: "ignoreReduceTransparency", reset: "ignore reduce transparency", title: "Ignore Reduce Transparency")
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
        gated = background + look + [inset, rows, stacked, account, legacyCompact]
        binder.add { [weak self] in
            guard let self else { return }
            let off = library.isRedesignOn ? nil : Self.offReason
            for r in self.gated where r.inertReason != off { r.inertReason = off }
            // "Use in" means nothing until Redesign is on.
            if self.useIn.isHidden == library.isRedesignOn { self.useIn.isHidden = !library.isRedesignOn; masterRow.needsLayout = true }
            // Each background shows only its own rows: Picture's inks and dots, Flower's motion, and the picture and
            // its tint for the two that draw it.
            let mode = self.client.string("redesignBackground") == "gradient" ? "flower" : self.client.string("redesignBackground")
            let shown: [(SettingsRowView, Bool)] = [(picture, mode != "flower"), (tint, mode != "flower"), (ink, mode == "dither"),
                                                     (dots, mode == "dither"), (animate, mode == "flower"), (threadFlower, mode == "flower")]
            var changed = false
            for (r, show) in shown where r.isHidden == show { r.isHidden = !show; changed = true }
            let readingOff = off ?? Self.readingWidthReason(self.client.string("chatWidth"))
            if reading.inertReason != readingOff { reading.inertReason = readingOff }
            if changed { self.needsLayout = true; self.onHeightChange?() }
        }
        // Most used first: the switch, the background, the colors, the layout, then the model picker's options.
        items = [
            section(nil, "Theme", [masterRow]),
            section("redesign-background-section", "Background", background + [transparency]),
            section("redesign-look", "Look", look),
            section("redesign-layout", "Layout", [inset, rows]),
            section("redesign-model-picker", "Model picker", [stacked, account]),
            section("redesign-legacy", "Legacy", [legacyCompact]),
        ]
        themeObserver = library.observe { [weak self] in self?.refresh() }
        binder.refresh()
    }

    isolated deinit { themeObserver.map { library.removeObserver($0) } }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The picture Redesign shows in the main panel: choose one, or go back to the desktop picture.
    private func pictureRow() -> SettingsRowView {
        let choose = ButtonView("Choose…", variant: .outline, size: .sm)
        let desktop = ButtonView("Use desktop", variant: .ghost, size: .sm)
        choose.action = { [weak self] in self?.choosePicture() }
        desktop.action = { [weak self] in DitherPicture.clear(); ThemeLibrary.shared.apply(); self?.refresh() }
        let group = SettingsControlGroup([desktop, choose], gap: 6)
        let r = row("redesign-picture", title: "Picture", detail: "The picture behind the chat, or your desktop picture until you choose one.", control: group)
        binder.add { [weak group] in
            desktop.isHidden = DitherPicture.path == nil
            group?.invalidateIntrinsicContentSize()
        }
        return r
    }

    /// How Redesign draws its background: the picture dithered in the main panel, as before, the picture blurred behind
    /// the whole window (the user, 2026-11-21: "either full blur or full dither"), or a dotted lotus over accent dots
    /// with no picture. Gradient's dots became Flower's field; a stored "gradient" loads as Flower.
    private func backgroundRow() -> SettingsRowView {
        let key = "redesignBackground", values = ["dither", "blur", "flower"]
        let toggle = ToggleGroupView(variant: .segmented, items: [("Picture", nil), ("Blur", nil), ("Flower", nil)], selected: 0)
        toggle.setAccessibilityLabel("Background")
        // "Style": the section above is titled Background.
        let r = row("redesign-background", title: "Style",
                    detail: "Draw your picture in dots behind the chat, blur it behind the whole window, or show a dotted lotus instead.",
                    control: toggle)
        toggle.onChange = { [weak self, weak toggle] i in
            guard let self else { return }
            // Clicking the pressed segment unpresses it; the choice stays.
            guard let i else { toggle?.selectedIndex = values.firstIndex(of: self.client.string(key)) ?? 0; return }
            self.context.writeClient?([key: .string(values[i])])
        }
        binder.add { [weak self, weak toggle] in
            guard let self else { return }
            toggle?.selectedIndex = values.firstIndex(of: self.client.string(key) == "gradient" ? "flower" : self.client.string(key)) ?? 0
        }
        return r
    }

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

    /// The lotus a thread draws under Flower (`LotusArt.ThreadLook`; the user, 2026-11-27: "make old and new a toggle
    /// they both look good"): the whole lotus beside the column, the default, or the smaller one from before.
    private func threadFlowerRow() -> SettingsRowView {
        let key = "redesignThreadFlower", values = ["large", "small"]
        let toggle = ToggleGroupView(variant: .segmented, items: [("Large", nil), ("Small", nil)], selected: 0)
        toggle.setAccessibilityLabel("Flower on a thread")
        let r = row("redesign-thread-flower", title: "Flower on a thread",
                    detail: "Show a whole lotus beside the conversation, or a smaller one that fades behind the text.",
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

    /// Where Picture's two inks come from (the user, 2026-11-21: "i like 2 ink"): the picture's own hue, the accent, or
    /// a color the user picks. Accent and Custom make that color the light ink and derive the deep one from its hue.
    private func inkRow() -> SettingsRowView {
        let key = "redesignInk", colorKey = "redesignInkColor", values = ["auto", "accent", "custom"]
        let toggle = ToggleGroupView(variant: .segmented, items: [("Auto", nil), ("Accent", nil), ("Custom", nil)], selected: 0)
        toggle.setAccessibilityLabel("Ink")
        let well = NSColorWell(style: .minimal)
        well.setAccessibilityLabel("Custom ink color")
        well.frame.size = NSSize(width: 38, height: 24)
        let target = InkWellTarget { [weak self] color in
            guard let self, let c = color.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                             Int((c.blueComponent * 255).rounded()))
            self.context.writeClient?([colorKey: .string(hex), key: .string("custom")])
        }
        well.target = target
        well.action = #selector(InkWellTarget.changed(_:))
        objc_setAssociatedObject(well, &InkWellTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        let group = SettingsControlGroup([well, toggle], gap: 8)
        let r = row("redesign-ink", title: "Ink",
                    detail: "Where Picture's two colors come from: the picture itself, the accent, or a color you pick.",
                    control: group)
        toggle.onChange = { [weak self, weak toggle] i in
            guard let self else { return }
            guard let i else { toggle?.selectedIndex = values.firstIndex(of: self.client.string(key)) ?? 0; return }
            self.context.writeClient?([key: .string(values[i])])
        }
        binder.add { [weak self, weak toggle, weak well, weak group] in
            guard let self else { return }
            let mode = self.client.string(key)
            toggle?.selectedIndex = values.firstIndex(of: mode) ?? 0
            well?.isHidden = mode != "custom"
            if case let .custom(c) = DitherInk(mode: "custom", color: self.client.string(colorKey)),
               well?.color.usingColorSpace(.sRGB).map({ SIMD3($0.redComponent, $0.greenComponent, $0.blueComponent) }) != c {
                well?.color = NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
            }
            group?.invalidateIntrinsicContentSize()
        }
        return r
    }

    /// The size of Picture's dots (the user, 2026-11-21, on 3pt dots on a 2x laptop: "i feel like the pixels might be a
    /// bit big"). Fine is 1.5pt, 3 pixels on a Retina screen; at 1x it draws Medium's 2pt, since 1.5pt falls between
    /// pixels there (`DitherDotSize`).
    private func dotSizeRow() -> SettingsRowView {
        let key = "redesignDotSize", values = DitherDotSize.allCases.map(\.rawValue)
        let toggle = ToggleGroupView(variant: .segmented, items: [("Fine", nil), ("Medium", nil), ("Coarse", nil)], selected: 1)
        toggle.setAccessibilityLabel("Dot size")
        let r = row("redesign-dot-size", title: "Dot size",
                    detail: "How big Picture's dots are, with Fine keeping the most detail on a Retina screen.",
                    control: toggle)
        toggle.onChange = { [weak self, weak toggle] i in
            guard let self else { return }
            guard let i else { toggle?.selectedIndex = values.firstIndex(of: self.client.string(key)) ?? 1; return }
            self.context.writeClient?([key: .string(values[i])])
        }
        binder.add { [weak self, weak toggle] in
            guard let self else { return }
            toggle?.selectedIndex = values.firstIndex(of: self.client.string(key)) ?? 1
        }
        return r
    }

    /// "Dim behind text" (the user, 2026-11-21: "allow me to change the dimness of the opacity of the line down the
    /// middle"): how much the background is held back behind a thread's text, 0 to 100 with the earlier look at 70
    /// (`TextDim`). Picture moves its cap's floors and Flower its mask's depth, both from `redesignTextDim`. Blur's dim
    /// over the whole thread page is the same thing for Blur, so this row folds in the old "Background dim": in Blur it
    /// shows and writes `ditherBackgroundDim`, mapped so its 35% default sits at 70 too and a saved value carries over.
    private func textDimRow() -> SettingsRowView {
        let control = SettingsSliderControl(value: Double(TextDim.standard), range: 0...100, step: 1, outputWidth: 48)
        control.format = { "\(Int($0))%" }
        control.slider.setAccessibilityLabel("Dim behind text")
        let r = row("redesign-text-dim", title: "Dim behind text", detail: "How much the background is held back behind a thread\u{2019}s text.",
                    control: control)
        let slot = ResetSlot(label: "dim behind text")
        r.accessories = [slot]
        let blurKey = "ditherBackgroundDim", key = "redesignTextDim"
        let blur = { [weak self] in self?.client.string("redesignBackground") == "blur" }
        slot.action = { [weak self] in
            let k = blur() ? blurKey : key
            self?.context.writeClient?([k: ClientSettings.fields[k]!.defaultValue])
        }
        control.onChange = { [weak self] v in
            let position = Int(v.rounded())
            self?.context.writeClient?(blur() ? [blurKey: .number(Double(TextDim.blurDim(at: position)))] : [key: .number(Double(position))])
        }
        binder.add { [weak self, weak control, weak r] in
            guard let self else { return }
            let position = Self.textDimPosition(self.client)
            if control?.value != Double(position) { control?.value = Double(position) }
            slot.isShown = !self.client.isDefault(blur() ? blurKey : key)
            let status = position < 50 ? Self.textDimWarning : nil
            if r?.status != status { r?.status = status }
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

    static let textDimWarning = "Text may be harder to read over bright backgrounds."

    /// Where "Dim behind text" stands for the chosen background.
    static func textDimPosition(_ client: ClientSettings) -> Int {
        client.string("redesignBackground") == "blur" ? TextDim.position(blurDim: client.int("ditherBackgroundDim")) : client.int("redesignTextDim")
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

    private func choosePicture() {
        DitherPicture.choose(in: window, onError: { [weak self] in self?.context.toast?("Couldn’t use that picture", $0, .error) }) { [weak self] in
            ThemeLibrary.shared.apply()
            self?.refresh()
        }
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

/// Hands the ink well's color to the Ink row. NSColorWell keeps its target weakly, so the well holds this.
private final class InkWellTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    let onChange: (NSColor) -> Void
    init(_ onChange: @escaping (NSColor) -> Void) { self.onChange = onChange }
    @MainActor @objc func changed(_ sender: NSColorWell) { onChange(sender.color) }
}
