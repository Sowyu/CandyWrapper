import AppKit
import DesignSystem

/// One machine a new thread can run on (`EnvironmentOption`, BranchToolbar.logic.ts:17-24).
public struct RunOnOption: Equatable, Sendable {
    public var environmentId: String
    public var label: String
    public var machine: String
    public init(environmentId: String, label: String, machine: String) {
        self.environmentId = environmentId
        self.label = label
        self.machine = machine
    }
}

/// The context strip under the draft composer (`ComposerSurface.ContextStrip`, ComposerSurface.tsx:104-117)
/// holding the "Run on" control (`BranchToolbarEnvironmentSelector`). The strip is inset 22 per side,
/// starts 16 above the composer's bottom (`-mt-4`) and shows 32 below it (`pt-5`, a 24 row, `pb-1`).
/// Its top 16 sit under the composer and are masked off (`mask-b-from-4`); below that it continues the
/// composer's glass, outline (`rounded-b-2xl`) and, in dark, the 10px seam shade (`composer-seam-below`).
public final class ComposerContextStripView: DSView {
    public static let height: CGFloat = 48, overlap: CGFloat = 16, inset: CGFloat = 22

    public let runOn = RunOnControl()
    private let clip = DSView()
    private let blur = BackdropBlurView()
    private let surface = DSView()
    private let seam = CAGradientLayer()
    private let tint = CALayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clip.clipsToBounds = true
        addSubview(clip)
        blur.cornerRadius = 16
        clip.addSubview(blur)
        surface.layer?.cornerRadius = 16
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        surface.layer?.addSublayer(tint)
        surface.layer?.addSublayer(seam)
        clip.addSubview(surface)
        addSubview(runOn)
    }

    public override func updateLayer() {
        let dark = effectiveAppearance.isDark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.layer?.backgroundColor = Themed.color(light: \.card, 0.8, dark: \.surfaceRaised, 0.8).cgColor(in: self)
        surface.layer?.borderColor = (dark ? Themed.white(0.07) : Themed.black(0.08)).cgColor
        // Dark only: rgb(0 0 0 / 18%) at the seam fading out over 10px, over a 1% white fill.
        seam.isHidden = !dark
        tint.isHidden = !dark
        seam.colors = [Themed.black(0.18).cgColor, Themed.black(0).cgColor]
        tint.backgroundColor = Themed.white(0.01).cgColor
        CATransaction.commit()
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        clip.frame = NSRect(x: 0, y: Self.overlap, width: w, height: max(0, h - Self.overlap))
        // The whole strip box, so the rounded top corners fall in the masked band.
        surface.frame = NSRect(x: 0, y: -Self.overlap, width: w, height: h)
        blur.frame = surface.frame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.frame = surface.bounds
        seam.frame = CGRect(x: 0, y: Self.overlap, width: w, height: 10)
        seam.startPoint = CGPoint(x: 0.5, y: surface.isFlipped ? 0 : 1)
        seam.endPoint = CGPoint(x: 0.5, y: surface.isFlipped ? 1 : 0)
        CATransaction.commit()
        // `ps-1`, `pt-5`: the 24px row starts 20 down.
        let size = runOn.intrinsicContentSize
        runOn.frame = NSRect(x: 4, y: 20, width: min(size.width, max(0, w - 12)), height: size.height)
    }
}

/// `BranchToolbarEnvironmentSelector` (BranchToolbarEnvironmentSelector.tsx:29-139): a `ComposerSelectControl`
/// at size `xs` showing the machine glyph, the environment label and the chevron, with the label in a
/// tooltip. Height 24, 1px transparent border, padding 7, gap 4, 12px text in `muted-foreground/70`
/// (`foreground/80` on hover), `accent` fill on hover and while open. The 12px glyph has -2 margins
/// (`[&_svg]:-mx-0.5`); the 12px chevron at 50% has `ms-0 -me-1`. Locked (or with one machine) it is a
/// static row with no chevron and no negative margins.
public final class RunOnControl: ControlView {
    public var options: [RunOnOption] = [] { didSet { if options != oldValue { update() } } }
    public var selectedId: String? { didSet { if selectedId != oldValue { update() } } }
    /// `envLocked`, or nothing to choose between: the static label.
    public var locked = false { didSet { if locked != oldValue { update() } } }
    public var onChange: (@MainActor (String) -> Void)?

    private let glyph = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private let label = LabelView()
    private let chevron = IconView(definition: ComposerControlView.chevronDefinition, size: 12)
    private let fill = CALayer()
    private let ring = CALayer()
    private var tooltip: TooltipController?
    private(set) var openList: MenuPopupView?

    public init() {
        super.init(frame: .zero)
        scalesWhenPressed = false
        for l in [fill, ring] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "borderColor": NSNull(), "hidden": NSNull()] }
        fill.cornerRadius = 8
        ring.cornerRadius = 11
        ring.borderWidth = 2
        layer?.addSublayer(fill)
        layer?.addSublayer(ring)
        layer?.masksToBounds = false
        label.font = DSFont.ui(12)
        label.lineHeight = 16
        label.smoothsFont = true // the strip itself has no backdrop filter, so Chromium smooths its text
        addSubview(glyph)
        addSubview(label)
        addSubview(chevron)
        chevron.alphaValue = 0.5
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Run on")
        tooltip = TooltipController.attach(to: self, text: "Run on")
        update()
    }

    public var selected: RunOnOption? { options.first { $0.environmentId == selectedId } }
    var interactive: Bool { !locked && options.count > 1 }

    private func update() {
        let text = selected?.label ?? "Run on"
        label.text = text
        tooltip?.text = text
        glyph.kind = selected?.machine ?? "server"
        chevron.isHidden = !interactive
        setAccessibilityRole(interactive ? .popUpButton : .staticText)
        restyle()
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true // the strip sizes the control to its label
    }

    /// `ComposerContextLabel`: at most 240 wide, truncated.
    private var labelWidth: CGFloat { min(240, ceil(label.textWidth)) }

    public override var intrinsicContentSize: NSSize {
        let w = interactive ? 8 + 8 + 4 + labelWidth + 4 + 8 + 8 : 8 + 12 + 4 + labelWidth + 8
        return NSSize(width: w, height: 24)
    }

    public override func layout() {
        super.layout()
        fill.frame = bounds
        ring.frame = bounds.insetBy(dx: -3, dy: -3)
        let midY = bounds.height / 2
        var x: CGFloat = 8
        if interactive {
            glyph.frame = NSRect(x: x - 2, y: midY - 6, width: 12, height: 12)
            x += 8 + 4
            let room = max(0, bounds.width - x - 4 - 8 - 8)
            label.frame = NSRect(x: x, y: midY - 8, width: min(labelWidth, room), height: 16)
            chevron.frame = NSRect(x: label.frame.maxX + 4, y: midY - 6, width: 12, height: 12)
        } else {
            glyph.frame = NSRect(x: x, y: midY - 6, width: 12, height: 12)
            x += 12 + 4
            label.frame = NSRect(x: x, y: midY - 8, width: min(labelWidth, max(0, bounds.width - x - 8)), height: 16)
        }
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    public override func updateLayer() {
        fill.backgroundColor = interactive && state.hoverOrPressed ? Themed.color(\.accent).cgColor(in: self) : nil
        ring.isHidden = !(interactive && state.focusVisible)
        ring.borderColor = Themed.color(\.ring).cgColor(in: self)
    }

    private func restyle() {
        let color = interactive && state.hovered ? Themed.color(\.contrastForeground, 0.8) : Themed.color(\.contrastMutedForeground, 0.7)
        label.color = color
        glyph.color = color
        chevron.strokeColor = color
        needsDisplay = true
    }

    public override func performAction() {
        super.performAction()
        open()
    }

    /// Opens the list (`composer.host`, mod+shift+h). `SelectPopup alignItemWithTrigger={false}`: under the
    /// trigger, start aligned, 4 below, at least as wide as it; a "Run on" group label, then one item per machine.
    public func open() {
        guard interactive, let host = popupHost else { return }
        let list = MenuPopupView(items: listItems(), style: .select)
        list.minimumWidth = bounds.width
        list.hostPopup = host.open(list, trigger: self, placement: .dropdown, swallowsOutsideClick: true)
        list.highlightedIndex = options.firstIndex { $0.environmentId == selectedId }.map { $0 + 1 }
        openList = list
    }

    func listItems() -> [MenuItem] {
        var items: [MenuItem] = [.label("Run on")]
        for option in options {
            var item = MenuItem(option.label, kind: .radio(option.environmentId == selectedId))
            item.glyph = EnvironmentMachineIcon.definition(option.machine)
            item.extraBottom = 1
            item.action = { [weak self] in
                guard let self, option.environmentId != selectedId else { return }
                onChange?(option.environmentId)
            }
            items.append(item)
        }
        return items
    }
}
