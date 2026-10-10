import AppKit
import DesignSystem
import T3Protocol

/// Settings > Appearance (SettingsPanels.tsx `AppearanceSettingsPanel`, ThemeSettings.tsx `ThemeLibrary`'s
/// mode tiles). Every row is a client setting, so the page has no scope sentence
/// (`SETTINGS_DEVICE_ONLY_PATHS`).
// ponytail: no theme gallery, editor or import; CandyWrapper draws T3's default palette only. Add them with a theme runtime
public final class AppearanceSettingsView: SettingsPageBase {
    static let advancedKey = "settings.typographyAdvanced"
    private var typography: SettingsSectionView?
    private var advancedSwitch = SwitchView(isOn: false, size: .default)
    private lazy var simpleRows: [any SettingsGroupRow] = [interfaceFont(), fontRow("code-font", title: "Monospace font",
        detail: "Code blocks, diffs, file previews, and the terminal.", family: "fontFamilyCode", size: "fontSizeCode", range: 10...18,
        defaultFamily: "SF Mono", reset: "monospace font")]
    private lazy var advancedRows: [any SettingsGroupRow] = [interfaceFont(),
        fontRow("prompt-font", detail: "Only the box you write prompts in. Mono works well here.", family: "fontFamilyComposer", size: "fontSizePrompt",
                range: 12...20, defaultFamily: "SF Pro", reset: "prompt font"),
        fontRow("code-font", detail: "Code blocks, diffs, and file previews.", family: "fontFamilyCode", size: "fontSizeCode", range: 10...18,
                defaultFamily: "SF Mono", reset: "code font"),
        fontRow("terminal-font", detail: "Terminal output, independent from code blocks and diffs.", family: "fontFamilyTerminal",
                size: "fontSizeTerminal", range: 8...20, defaultFamily: "SF Mono", reset: "terminal font"),
        clientSwitch("font-smoothing", "Use thinner grayscale text smoothing instead of the macOS default.", key: "fontSmoothing", reset: "font smoothing")]
    private lazy var wordWrap = clientSwitch("word-wrap", "Wrap long lines in code blocks, tables, diffs, and file previews by default.",
                                             key: "wordWrap", reset: "word wrapping", label: "Wrap code, tables, diffs, and file previews by default")

    public override init(context: SettingsPageContext) {
        super.init(context: context)
        items = [colorsSection(), interfaceSection(), motionSection(), typographySection()]
    }

    /// A search jump to an advanced font row turns Advanced on first (`ADVANCED_TYPOGRAPHY_TARGET_IDS`).
    public override func anchor(_ id: String) -> NSView? {
        if ["prompt-font", "terminal-font", "font-smoothing"].contains(id), !isAdvanced { setAdvanced(true) }
        if id == "code-font" || id == "interface-font" { _ = typography }
        return super.anchor(id)
    }

    // MARK: Colors & themes

    private func colorsSection() -> SettingsPlainSectionView {
        let heading = SettingsSubheadingView(SettingsSearch.title("color-scheme"))
        let tiles = ModeTilesView()
        tiles.onPick = { [weak self] mode in self?.context.setAppearanceMode?(mode) }
        binder.add { [weak self, weak tiles] in tiles?.mode = self?.context.appearanceMode ?? "system" }
        let s = SettingsPlainSectionView()
        s.body = [heading, tiles]
        anchors["appearance"] = s
        return s
    }

    // MARK: Interface

    private func interfaceSection() -> SettingsSectionView {
        let contrast = sliderRow("setting-appearance-contrast", "Adjust the contrast of colors and borders across the interface.",
                                 key: "appearanceContrast", range: 50...200, step: 5, reset: "contrast")
        let glass = sliderRow("setting-glass-opacity", "Higher values make menus, dialogs, and the composer more solid.",
                              key: "glassOpacity", range: 40...100, step: 5, reset: "glass opacity")
        let identification = clientSelect("environment-identification", "Choose how Dev and Nightly environments are identified.",
                                          key: "environmentIdentificationMode", options: [("artwork", "Artwork"), ("pill", "Version pill"), ("none", "None")],
                                          width: 160, reset: "environment identification")
        anchors["appearance-interface"] = nil
        let diff = clientSelect("diff-color-scheme", "Choose colors for additions and deletions, including change counts.", key: "diffColorScheme",
                                options: [("red-green", "Red & green (default)"), ("blue-orange", "Blue & orange")], width: 160, reset: "diff colors",
                                hideIndicator: false)
        if let select = diff.control as? SelectView {
            select.valueLabels = ["Red & green", "Blue & orange"]
            let dots = DiffDotsView()
            select.leading = dots
            binder.add { [weak self] in dots.swapped = self?.client.string("diffColorScheme") == "blue-orange" }
        }
        let strip = clientSwitch("composer-context", "Keep branch and worktree controls below the composer after a thread starts.",
                                 key: "persistComposerContextStrip", reset: "composer context", label: "Keep composer context visible in active threads")
        let width = clientSelect("chat-width", "Set how wide messages and the composer can grow on large screens.", key: "chatWidth",
                                 options: [("comfortable", "Comfortable (default)"), ("wide", "Wide"), ("full", "Full")], width: 160,
                                 reset: "chat width", hideIndicator: false)
        (width.control as? SelectView)?.valueLabels = ["Comfortable", "Wide", "Full"]
        let s = section("appearance-interface", "Interface", [contrast, glass, identification, diff, strip, width])
        return s
    }

    private func sliderRow(_ id: String, _ detail: String, key: String, range: ClosedRange<Double>, step: Double, reset: String,
                           unit: String = "%", outputWidth: CGFloat = 48) -> SettingsRowView {
        let control = SettingsSliderControl(value: Double(client.int(key)), range: range, step: step, outputWidth: outputWidth)
        control.format = unit == "%" ? { "\(Int($0))%" } : { "\(Int($0)) ms" }
        control.slider.setAccessibilityLabel(SettingsSearch.title(id))
        let r = row(id, detail: detail, control: control)
        let slot = ResetSlot(label: reset)
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

    // MARK: Motion

    private func motionSection() -> SettingsSectionView {
        // ponytail: no PanelAnimationsPreview beside the slider; panels don't animate yet, so it would preview nothing
        let r = sliderRow("panel-animations", "Set how fast panels open and close.", key: "panelAnimationDurationMs", range: 0...400, step: 25,
                          reset: "panel animations", unit: "ms", outputWidth: 64)
        (r.control as? SettingsSliderControl)?.slider.setAccessibilityLabel("Panel animation duration")
        return section("motion", "Motion", [r])
    }

    // MARK: Typography

    private var isAdvanced: Bool { UserDefaults.standard.bool(forKey: Self.advancedKey) }

    private func setAdvanced(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.advancedKey)
        advancedSwitch.isOn = on
        typography?.group.rows = (on ? advancedRows : simpleRows) + [wordWrap]
        binder.refresh()
        onHeightChange?()
    }

    private func typographySection() -> SettingsSectionView {
        let s = SettingsSectionView(title: "Typography", rows: (isAdvanced ? advancedRows : simpleRows) + [wordWrap])
        anchors["typography"] = s
        let header = AdvancedToggleView(switchView: advancedSwitch)
        advancedSwitch.isOn = isAdvanced
        advancedSwitch.setAccessibilityLabel("Show advanced typography settings")
        advancedSwitch.onChange = { [weak self] on in self?.setAdvanced(on) }
        s.headerAction = header
        typography = s
        return s
    }

    private func interfaceFont() -> SettingsRowView {
        fontRow("interface-font", detail: "Everything outside code blocks and the terminal.", family: "fontFamilySans", size: "fontSizeInterface",
                range: 12...20, defaultFamily: "SF Pro", reset: "interface font")
    }

    /// `FontFamilySettingsRow`: a family input (the probed default as placeholder) and a size select, reset clears both.
    // ponytail: fonts store their family and size; the interface, prompt, code and terminal fonts don't follow them yet. Apply them when text styles become settings-driven
    private func fontRow(_ id: String, title: String? = nil, detail: String, family: String, size: String, range: ClosedRange<Int>,
                         defaultFamily: String, reset: String) -> SettingsRowView {
        let input = InputView(placeholder: defaultFamily, text: "", size: .sm)
        input.frame.size = NSSize(width: 176, height: 28)
        input.setAccessibilityLabel("\(title ?? SettingsSearch.title(id)) family")
        let sizes = Array(range)
        let select = settingsSelect(sizes.map { "\($0) px" }, width: 88)
        select.setAccessibilityLabel("\(title ?? SettingsSearch.title(id)) size")
        let r = row(id, title: title, detail: detail, control: SettingsControlGroup([input, select]))
        let slot = ResetSlot(label: reset)
        r.accessories = [slot]
        slot.action = { [weak self] in
            self?.context.writeClient?([family: .string(""), size: ClientSettings.fields[size]!.defaultValue])
        }
        // The family commits when typing pauses or on Return, only for a font this Mac has (or an empty field).
        input.onCommit = { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespaces)
            guard name.isEmpty || NSFontManager.shared.availableFontFamilies.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                input.isInvalid = true
                return
            }
            input.isInvalid = false
            self?.context.writeClient?([family: .string(name)])
        }
        select.onChange = { [weak self] i in self?.context.writeClient?([size: .number(Double(sizes[i]))]) }
        binder.add { [weak self, weak input, weak select] in
            guard let self else { return }
            if let input, !input.state.focused { input.text = self.client.string(family) }
            select?.selectedIndex = sizes.firstIndex(of: self.client.int(size))
            slot.isShown = !self.client.isDefault(family) || !self.client.isDefault(size)
        }
        return r
    }
}

/// The Typography header's "Advanced" label and switch (`text-xs font-medium text-muted-foreground gap-2`).
final class AdvancedToggleView: DSView {
    private let label = LabelView("Advanced", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))
    let switchView: SwitchView
    init(switchView: SwitchView) {
        self.switchView = switchView
        super.init(frame: .zero)
        label.lineHeight = 16
        addSubview(label)
        addSubview(switchView)
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.textWidth) + 1 + 8 + switchView.intrinsicContentSize.width, height: 28)
    }
    override func layout() {
        super.layout()
        let s = switchView.intrinsicContentSize
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: ceil(label.textWidth) + 1, height: 16)
        switchView.frame = NSRect(x: bounds.width - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }
}

/// The diff colors select's two `size-2` dots (`bg-diff-deletion` then `bg-diff-addition`, reversed for blue and orange).
final class DiffDotsView: DSView {
    var swapped = false { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) { super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 8)) }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let blue = swapped
        let deletion = blue ? NSColor(srgbRed: 0.98, green: 0.45, blue: 0.09, alpha: 1) : Themed.color(\.diffDeletion)
        let addition = blue ? NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1) : Themed.color(\.diffAddition)
        let (first, second) = blue ? (addition, deletion) : (deletion, addition)
        first.setFill(); NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        second.setFill(); NSBezierPath(ovalIn: NSRect(x: 12, y: 0, width: 8, height: 8)).fill()
    }
}

/// The three appearance tiles (ThemeSettings.tsx:720-751): System, Light and Dark, each a 140pt wireframe
/// of the app above its label. The active tile has `bg-accent/30` and an inset 1px `ring`.
final class ModeTilesView: DSView, SettingsGroupRow {
    var mode = "system" { didSet { tiles.forEach { $0.isActive = $0.mode == mode } } }
    var onPick: ((String) -> Void)?
    private var tiles: [Tile] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Appearance mode")
        for m in ["system", "light", "dark"] {
            let t = Tile(mode: m)
            t.action = { [weak self] in self?.onPick?(m) }
            tiles.append(t)
            addSubview(t)
        }
        tiles[0].isActive = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 8 + 140 + 6 + 16 + 8 }

    override func layout() {
        super.layout()
        let w = (bounds.width - 24) / 3
        for (i, t) in tiles.enumerated() { t.frame = NSRect(x: CGFloat(i) * (w + 12), y: 0, width: w, height: bounds.height) }
    }

    final class Tile: ControlView {
        let mode: String
        var isActive = false { didSet { restyle(); setAccessibilityValue(isActive) } }
        private let decoration = BoxDecorationLayer()
        private let wireframe: Wireframe
        private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))

        init(mode: String) {
            self.mode = mode
            wireframe = Wireframe(mode: mode)
            super.init(frame: .zero)
            scalesWhenPressed = false
            decoration.host = self
            layer?.addSublayer(decoration)
            label.text = mode == "system" ? "System" : mode == "light" ? "Light" : "Dark"
            label.lineHeight = 16
            label.alignment = .center
            addSubview(wireframe)
            addSubview(label)
            setAccessibilityRole(.button)
            setAccessibilityLabel(mode == "system" ? "Follow the system appearance" : "Use \(mode) mode")
            restyle()
        }

        override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

        private func restyle() {
            var box = BoxStyle()
            box.radius = 12
            if isActive {
                box.fill = Themed.color(\.accent, 0.3)
                box.border = .clear
                box.shadows = [BoxShadow(spread: 1, color: Themed.color(\.ring), inset: true)]
            } else {
                box.border = Themed.color(\.border, 0.7)
                box.fill = state.hovered ? Themed.color(\.accent, 0.1) : Themed.color(\.card, 0.6)
            }
            decoration.boxStyle = box
            label.color = isActive ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        }

        override func layout() {
            super.layout()
            decoration.layout(boxSize: bounds.size)
            wireframe.frame = NSRect(x: 9, y: 9, width: bounds.width - 18, height: 140)
            label.frame = NSRect(x: 9, y: 9 + 140 + 6, width: bounds.width - 18, height: 16)
        }
    }

    /// `ThemeWireframe` with T3's standard preview colors (themePreview.ts, ThemePreviewCircles.tsx).
    final class Wireframe: DSView {
        let mode: String
        init(mode: String) { self.mode = mode; super.init(frame: .zero) }
        override var wantsUpdateLayer: Bool { false }

        struct Colors { let canvas, sidebar, surface, accentSurface, messageSurface, messageAction: NSColor }
        static func hex(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        static let light = Colors(canvas: hex(0xfcfcfc), sidebar: hex(0xfafafa), surface: hex(0xffffff), accentSurface: hex(0xf4f4f5),
                                  messageSurface: hex(0xe4e4e7), messageAction: hex(0x4f46e5))
        static let dark = Colors(canvas: hex(0x0a0a0a), sidebar: hex(0x0f0f10), surface: hex(0x121212), accentSurface: hex(0x27272a),
                                 messageSurface: hex(0x27272a), messageAction: hex(0x8b9cff))

        override func draw(_ dirtyRect: NSRect) {
            let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).addClip()
            if mode == "system" {
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: 0, y: 0, width: bounds.width / 2 - 1, height: bounds.height).clip()
                pane(Self.light)
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: bounds.width / 2 + 1, y: 0, width: bounds.width / 2 - 1, height: bounds.height).clip()
                pane(Self.dark)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                pane(mode == "dark" ? Self.dark : Self.light)
            }
            NSGraphicsContext.restoreGraphicsState()
            Themed.color(\.border, 0.6).setStroke()
            outer.lineWidth = 1
            outer.stroke()
        }

        private func pane(_ c: Colors) {
            let W = bounds.width, H = bounds.height
            let line = NSColor(srgbRed: 127 / 255, green: 127 / 255, blue: 127 / 255, alpha: 0.25)
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * W, y: y * H, width: w * W, height: h * H) }
            func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0, alpha: CGFloat = 1, ring: Bool = false) {
                let p = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                color.withAlphaComponent(color.alphaComponent * alpha).setFill(); p.fill()
                if ring { line.setStroke(); let i = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5)); i.lineWidth = 1; i.stroke() }
            }
            fill(bounds, c.canvas)
            fill(r(0, 0, 0.22, 1), c.sidebar)
            line.setFill(); NSRect(x: 0.22 * W - 1, y: 0, width: 1, height: H).fill()
            fill(r(0.03, 0.08, 0.16, 0.08), c.surface, radius: 6, ring: true)
            fill(r(0.03, 0.22, 0.16, 0.07), c.accentSurface, radius: 6)
            fill(r(0.03, 0.32, 0.16, 0.07), c.messageSurface, radius: 6, alpha: 0.7)
            fill(r(0.03, 0.42, 0.16, 0.07), c.messageSurface, radius: 6, alpha: 0.5)
            fill(r(1 - 0.28 - 0.24, 0.11, 0.24, 0.09), c.messageSurface, radius: 8)
            fill(r(0.27, 0.28, 0.34, 0.05), line, radius: 2)
            fill(r(0.27, 0.38, 0.26, 0.05), line, radius: 2)
            let composer = r(0.26, 1 - 0.08 - 0.15, 1 - 0.26 - 0.06, 0.15)
            fill(composer, c.surface, radius: 6, ring: true)
            let ch = composer.height
            fill(NSRect(x: composer.minX + 4, y: composer.midY - ch * 0.13, width: composer.width * 0.34, height: ch * 0.26), line, radius: ch * 0.13, alpha: 0.7)
            let dot = ch * 0.58
            fill(NSRect(x: composer.maxX - 4 - dot, y: composer.midY - dot / 2, width: dot, height: dot), c.messageAction, radius: dot / 2)
            let island = r(1 - 0.05 - 0.20, 0.08, 0.20, 0.46)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.shadowBlurRadius = 5
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.14); shadow.set()
            fill(island, c.surface, radius: 8)
            NSGraphicsContext.restoreGraphicsState()
            fill(island, c.surface, radius: 8, ring: true)
            for row in 0..<3 {
                let rowRect = NSRect(x: island.minX + island.width * 0.11, y: island.minY + island.height * (0.10 + CGFloat(row) * 0.30),
                                     width: island.width * 0.78, height: island.height * 0.20)
                let d = rowRect.height * 0.26
                let colors = [Self.hex(0x34d399), c.messageAction, Self.hex(0xfbbf24)]
                fill(NSRect(x: rowRect.minX, y: rowRect.midY - d / 2, width: d, height: d), colors[row], radius: d / 2, alpha: 0.55)
                fill(NSRect(x: rowRect.minX + d + 4, y: rowRect.midY - rowRect.height * 0.15, width: rowRect.width * 0.52, height: rowRect.height * 0.30), line, radius: 2)
            }
        }
    }
}
