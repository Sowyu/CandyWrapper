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
    static let gradientReason = "Gradient uses no picture. Choose Picture or Blur to change this."
    static let flowerReason = "Flower uses no picture. Choose Picture or Blur to change this."
    static let animateReason = "Only Gradient and Flower move. Choose one of them to change this."
    static let inkReason = "Only Picture draws in inks. Choose Picture to change this."
    static let dotSizeReason = "Only Picture's dots change size. Choose Picture to change this."
    static let dimReason = "Picture thins its dots behind text instead of dimming. Choose Blur to change this."
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
                            detail: "CandyWrapper's own look, with a picture behind the chat. Off goes back to the theme you had before.",
                            control: SettingsControlGroup([useIn, master], gap: 12))
        binder.add { [weak self, weak master] in
            master?.isOn = library.isRedesignOn
            let shown = library.isRedesignOn ? library.redesignAppearances : library.redesignUseIn
            if let i = Self.useInChoices.firstIndex(where: { $0.1 == shown }), self?.useIn.selectedIndex != i { self?.useIn.selectedIndex = i }
        }

        let picture = pictureRow(), dim = dimRow()
        // Capy's no-picture dither moves (the user, 2026-11-21: "capys plain dither isnt just static").
        let animate = clientSwitch("redesign-gradient-animate", "Let Gradient's dots drift on the new-thread page, and Flower's lotus bloom when a thread opens and turn slowly. Both stop while the window is in the background and under Reduce Motion.",
                                   key: "redesignGradientAnimate", reset: "animate background", title: "Animate background")
        let tint = clientSwitch("redesign-tint", "Lean the window's surfaces a little toward the picture's color.",
                                key: "redesignTintFromPicture", reset: "tint from picture", title: "Tint from picture")
        let ink = inkRow(), dots = dotSizeRow()
        let look: [SettingsRowView] = [picture, backgroundRow(), ink, dots, tint, animate, dim, accentRow(), avatarsRow()]
        let transparency = clientSwitch("ignore-reduce-transparency", "Show the picture and blur as if Reduce Transparency were off in macOS.",
                                        key: "ignoreReduceTransparency", reset: "ignore reduce transparency", title: "Ignore Reduce Transparency")
        let collapse = clientSwitch("composer-collapse",
                                    "Rest the composer of an existing thread into a single line when you scroll the conversation. Focus the composer or start typing to expand it again.",
                                    key: "composerCollapseOnScroll", reset: "collapse composer on scroll", title: "Collapse composer on scroll")
        let stacked = clientSwitch("redesign-stacked-picker", "One column with six models at a time over Reasoning and the footer. Off shows the models with a details pane beside them.",
                                   key: "redesignStackedPicker", reset: "stacked model picker", title: "Stacked model picker")
        let account = clientSwitch("redesign-picker-account", "The provider's account and usage bar at the top of the details pane, or above the models when stacked.",
                                   key: "redesignPickerAccount", reset: "account and limits", title: "Account and limits in the model picker")
        gated = look + [collapse, stacked, account]
        binder.add { [weak self] in
            guard let self else { return }
            let off = library.isRedesignOn ? nil : Self.offReason
            for r in self.gated where r.inertReason != off { r.inertReason = off }
            // Gradient shows no picture, so the picture's own settings do nothing.
            let background = self.client.string("redesignBackground")
            let pictureOff = off ?? (background == "gradient" ? Self.gradientReason : background == "flower" ? Self.flowerReason : nil)
            for r in [picture, tint] where r.inertReason != pictureOff { r.inertReason = pictureOff }
            // The dim only darkens Blur; Picture's inks only draw Picture.
            let dimOff = pictureOff ?? (background == "blur" ? nil : Self.dimReason)
            if dim.inertReason != dimOff { dim.inertReason = dimOff }
            let inkOff = off ?? (background == "dither" ? nil : Self.inkReason)
            if ink.inertReason != inkOff { ink.inertReason = inkOff }
            let dotsOff = off ?? (background == "dither" ? nil : Self.dotSizeReason)
            if dots.inertReason != dotsOff { dots.inertReason = dotsOff }
            let animateOff = off ?? (background == "gradient" || background == "flower" ? nil : Self.animateReason)
            if animate.inertReason != animateOff { animate.inertReason = animateOff }
        }
        items = [
            section(nil, "Theme", [masterRow]),
            section("redesign-look", "Look", look + [transparency]),
            section("redesign-composer", "Composer", [collapse]),
            section("redesign-model-picker", "Model picker", [stacked, account]),
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
        let r = row("redesign-picture", title: "Picture", detail: "The picture behind the chat. Without one it uses the desktop picture.", control: group)
        binder.add { [weak group] in
            desktop.isHidden = DitherPicture.path == nil
            group?.invalidateIntrinsicContentSize()
        }
        return r
    }

    /// How Redesign draws its background: the picture dithered in the main panel, as before, the picture blurred behind
    /// the whole window (the user, 2026-11-21: "either full blur or full dither"), or accent dots with no picture at the
    /// top of a new thread, like Capy ("add a dither option without an image").
    private func backgroundRow() -> SettingsRowView {
        let key = "redesignBackground", values = ["dither", "blur", "gradient", "flower"]
        let toggle = ToggleGroupView(variant: .segmented, items: [("Picture", nil), ("Blur", nil), ("Gradient", nil), ("Flower", nil)], selected: 0)
        toggle.setAccessibilityLabel("Background")
        let r = row("redesign-background", title: "Background",
                    detail: "Picture draws your picture in dots behind the chat. Blur softens it behind the whole window. Gradient and Flower use no picture: accent dots at the top of a new thread, or a dotted lotus.",
                    control: toggle)
        toggle.onChange = { [weak self, weak toggle] i in
            guard let self else { return }
            // Clicking the pressed segment unpresses it; the choice stays.
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
                    detail: "The two colors Picture draws in. Auto takes them from the picture. Accent and Custom use that color for the light ink and a deeper shade of it for the dark one.",
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
                    detail: "How big Picture's dots are. Fine keeps the most detail. On a screen that isn't Retina, Fine draws the same dots as Medium.",
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

    /// How much Redesign dims its blurred picture behind an open thread (the user, 2026-10-22). Picture lays no dim
    /// since 2026-11-21: its dots thin behind text instead.
    private func dimRow() -> SettingsRowView {
        let key = "ditherBackgroundDim"
        let control = SettingsSliderControl(value: Double(client.int(key)), range: 0...90, step: 5, outputWidth: 48)
        control.format = { "\(Int($0))%" }
        control.slider.setAccessibilityLabel("Background dim")
        let r = row("background-dim", title: "Background dim", detail: "How much the blurred picture dims behind an open thread.", control: control)
        let slot = ResetSlot(label: "background dim")
        r.accessories = [slot]
        slot.action = { [weak self] in self?.context.writeClient?([key: ClientSettings.fields[key]!.defaultValue]) }
        control.onChange = { [weak self] v in self?.context.writeClient?([key: .number(v)]) }
        binder.add { [weak self, weak control] in
            guard let self else { return }
            control?.value = Double(self.client.int(key))
            slot.isShown = !self.client.isDefault(key)
        }
        return r
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
