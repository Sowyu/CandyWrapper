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
}

/// The Redesign tab, CandyWrapper's own: the switch that turns Redesign on, then every setting only Redesign uses.
/// The switch is the theme picker's own setting, so the two always agree. While Redesign is off the rows under it
/// stay visible and inert, except Ignore Reduce Transparency, which the Glass theme reads too.
public final class RedesignSettingsView: SettingsPageBase {
    static let offReason = "Turn on Redesign to change this."
    static let gradientReason = "Gradient uses no picture. Choose Picture or Blur to change this."
    static let animateReason = "Only Gradient moves. Choose Gradient to change this."
    private let library: ThemeLibrary
    private var themeObserver: Int?
    /// The master switch, bound to the theme picker's setting.
    let master: SwitchView
    /// The rows inert while Redesign is off: all but the switch and Ignore Reduce Transparency.
    private(set) var gated: [SettingsRowView] = []

    public convenience override init(context: SettingsPageContext) { self.init(context: context, library: .shared) }

    init(context: SettingsPageContext, library: ThemeLibrary) {
        self.library = library
        master = SwitchView(isOn: library.isRedesignOn)
        super.init(context: context)
        master.setAccessibilityLabel("Redesign")
        master.onChange = { on in library.setRedesign(on) }
        let masterRow = row("redesign", title: "Redesign",
                            detail: "CandyWrapper's own look, with a picture behind the chat. Off goes back to the theme you had before.",
                            control: master)
        binder.add { [weak master] in master?.isOn = library.isRedesignOn }

        let picture = pictureRow(), dim = dimRow()
        // Capy's no-picture dither moves (the user, 2026-11-21: "capys plain dither isnt just static").
        let animate = clientSwitch("redesign-gradient-animate", "Let Gradient's dots drift on the new-thread page. They stop while the window is in the background and under Reduce Motion.",
                                   key: "redesignGradientAnimate", reset: "animate gradient", title: "Animate gradient")
        let tint = clientSwitch("redesign-tint", "Lean the window's surfaces a little toward the picture's color.",
                                key: "redesignTintFromPicture", reset: "tint from picture", title: "Tint from picture")
        let look: [SettingsRowView] = [picture, backgroundRow(), tint, animate, dim, accentRow()]
        let transparency = clientSwitch("ignore-reduce-transparency", "Show the picture, Glass and blur as if Reduce Transparency were off in macOS.",
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
            let pictureOff = off ?? (self.client.string("redesignBackground") == "gradient" ? Self.gradientReason : nil)
            for r in [picture, tint, dim] where r.inertReason != pictureOff { r.inertReason = pictureOff }
            let animateOff = off ?? (self.client.string("redesignBackground") == "gradient" ? nil : Self.animateReason)
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
        let key = "redesignBackground", values = ["dither", "blur", "gradient"]
        let toggle = ToggleGroupView(variant: .segmented, items: [("Picture", nil), ("Blur", nil), ("Gradient", nil)], selected: 0)
        toggle.setAccessibilityLabel("Background")
        let r = row("redesign-background", title: "Background",
                    detail: "Picture draws your picture in dots behind the chat. Blur softens it behind the whole window. Gradient uses no picture: accent-colored dots fade in at the top of a new thread.",
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

    /// How much Redesign dims its picture behind an open thread (the user, 2026-10-22).
    private func dimRow() -> SettingsRowView {
        let key = "ditherBackgroundDim"
        let control = SettingsSliderControl(value: Double(client.int(key)), range: 0...90, step: 5, outputWidth: 48)
        control.format = { "\(Int($0))%" }
        control.slider.setAccessibilityLabel("Background dim")
        let r = row("background-dim", title: "Background dim", detail: "How much the picture dims behind an open thread.", control: control)
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
        toolTip = accent.label
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
