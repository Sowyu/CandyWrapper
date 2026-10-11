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

/// The context strip under the draft composer (`ComposerSurface.ContextStrip`, ComposerSurface.tsx:104-117).
/// In a Git project it holds the run context (machine and workspace mode) on the left and the branch on the
/// right (BranchToolbar.tsx:780-865; the composer is never wider than `@3xl`, so this is the only Git layout);
/// elsewhere only the "Run on" control (`BranchToolbarEnvironmentSelector`). The strip is inset 22 per side,
/// starts 16 above the composer's bottom (`-mt-4`) and shows 32 below it (`pt-5`, a 24 row, `pb-1`).
/// Its top 16 sit under the composer and are masked off (`mask-b-from-4`); below that it continues the
/// composer's glass, outline (`rounded-b-2xl`) and, in dark, the 10px seam shade (`composer-seam-below`).
public final class ComposerContextStripView: DSView {
    public static let height: CGFloat = 48, overlap: CGFloat = 16, inset: CGFloat = 22

    public let runOn = RunOnControl().menuTrigger()
    /// `RunContextSelector` in the composer.
    public let runContext = ComposerContextControl().menuTrigger()
    /// `BranchToolbarBranchSelector` in the composer.
    public let branch = ComposerContextControl()
    /// `showGitControls`: the run context and the branch replace "Run on".
    public var showsGitControls = false {
        didSet {
            guard showsGitControls != oldValue else { return }
            runOn.isHidden = showsGitControls
            runContext.isHidden = !showsGitControls
            branch.isHidden = !showsGitControls
            needsLayout = true
        }
    }
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
        runContext.setAccessibilityLabel("Workspace")
        runContext.plainChevron = true
        branch.plainChevron = true
        branch.glyphs = [IconName.gitBranch.definition]
        branch.glyphAlpha = 0.7
        branch.middleTruncates = true
        branch.setAccessibilityLabel("Branch")
        for c in [runContext, branch] { c.isHidden = true; addSubview(c) }
        for c in [runOn, runContext, branch] as [ComposerContextControl] { c.onSizeChange = { [weak self] in self?.needsLayout = true } }
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
        // `ps-1 pe-2 pt-5`: the 24px row starts 20 down.
        guard showsGitControls else {
            let size = runOn.intrinsicContentSize
            runOn.frame = NSRect(x: 4, y: 20, width: min(size.width, max(0, w - 12)), height: size.height)
            return
        }
        // `gap-1`: the run context takes at most 48% (`max-w-[48%]`), the empty controls host flexes, and the
        // branch sits at the end (`justify-end`), giving way first.
        let inner = max(0, w - 12)
        let left = min(runContext.intrinsicContentSize.width, (inner * 0.48).rounded(.down))
        runContext.frame = NSRect(x: 4, y: 20, width: left, height: 24)
        let right = min(branch.intrinsicContentSize.width, max(0, inner - left - 8))
        branch.frame = NSRect(x: w - 8 - right, y: 20, width: right, height: 24)
    }
}

/// A composer context control (`ComposerControl` size `xs` holding a `ComposerContextLabel`, ComposerControl.tsx,
/// ComposerContextLabel.tsx): one or two 12px glyphs, the label (at most 240 wide) and a 12px chevron. Height 24,
/// 1px transparent border, padding 7, gap 4, 12px text in `muted-foreground/70` (`foreground/80` on hover),
/// `accent` fill on hover and while open. A single glyph has -2 margins (`[&_svg]:-mx-0.5`); a pair sits 2 apart
/// with no margins (`mx-0!` and `gap-0.5`). The chevron at 50% has `ms-0 -me-1`. Not interactive, it is the
/// static row (`inline-flex h-6 px-1.75`) with no chevron and no negative margins.
open class ComposerContextControl: ControlView {
    public var onContextMenu: ((NSEvent, NSView) -> Void)?
    public override func rightMouseDown(with event: NSEvent) { onContextMenu?(event, self) }
    public var glyphs: [IconDefinition] = [] { didSet { if glyphs != oldValue { rebuildGlyphs() } } }
    /// The glyphs' opacity (the branch icon is `opacity-70`).
    public var glyphAlpha: CGFloat = 1 { didSet { glyphViews.forEach { $0.alphaValue = glyphAlpha } } }
    public var text = "" { didSet { if text != oldValue { textChanged() } } }
    /// `MiddleTruncate`: a branch keeps its end.
    public var middleTruncates = false { didSet { textChanged() } }
    public var interactive = true { didSet { if interactive != oldValue { update() } } }
    /// The tooltip; nil shows the label.
    public var tooltipText: String? { didSet { tooltip?.text = tooltipText ?? text } }
    /// A child `ChevronDownIcon` (stroke 2, `-mx-0.5`) instead of `ComposerSelectControl`'s own chevron
    /// (stroke 2.25, `ms-0 -me-1`): the run context and branch triggers.
    public var plainChevron = false {
        didSet {
            chevron.removeFromSuperview()
            chevron = IconView(definition: plainChevron ? IconName.chevronDown.definition : ComposerControlView.chevronDefinition, size: 12)
            chevron.alphaValue = 0.5
            addSubview(chevron)
            update()
        }
    }
    /// Called when the intrinsic width changes, so the strip lays out again.
    public var onSizeChange: (@MainActor () -> Void)?

    private var glyphViews: [IconView] = []
    private let label = LabelView()
    private let middle = MiddleTruncateView("", font: DSFont.ui(12))
    private var chevron = IconView(definition: ComposerControlView.chevronDefinition, size: 12)
    private let fill = CALayer()
    private let ring = CALayer()
    private var tooltip: TooltipController?

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
        middle.lineHeight = 16
        middle.showsTitle = false
        middle.isHidden = true
        addSubview(label)
        addSubview(middle)
        addSubview(chevron)
        chevron.alphaValue = 0.5
        tooltip = TooltipController.attach(to: self, text: "")
        update()
    }

    private func rebuildGlyphs() {
        glyphViews.forEach { $0.removeFromSuperview() }
        glyphViews = glyphs.map { IconView(definition: $0, size: 12) }
        glyphViews.forEach { $0.alphaValue = glyphAlpha; addSubview($0) }
        update()
    }

    private func textChanged() {
        label.text = middleTruncates ? "" : text
        middle.value = middleTruncates ? text : ""
        label.isHidden = middleTruncates
        middle.isHidden = !middleTruncates
        tooltip?.text = tooltipText ?? text
        setAccessibilityValue(text)
        update()
    }

    func update() {
        chevron.isHidden = !interactive
        setAccessibilityRole(interactive ? .popUpButton : .staticText)
        restyle()
        invalidateIntrinsicContentSize()
        needsLayout = true
        onSizeChange?()
    }

    private var textWidth: CGFloat { middleTruncates ? middle.intrinsicContentSize.width : ceil(label.textWidth) }
    /// `ComposerContextLabel`: at most 240 wide, truncated.
    private var labelWidth: CGFloat { min(240, textWidth) }
    /// The glyphs' advance: a single glyph loses its -2 margins when interactive.
    private var glyphAdvance: CGFloat {
        switch glyphViews.count {
        case 0: 0
        case 1: interactive ? 8 : 12
        default: CGFloat(glyphViews.count) * 12 + CGFloat(glyphViews.count - 1) * 2
        }
    }

    open override var intrinsicContentSize: NSSize {
        let lead = glyphViews.isEmpty ? 0 : glyphAdvance + 4
        let w = interactive ? 8 + lead + labelWidth + 4 + 8 + 8 : 8 + lead + labelWidth + 8
        return NSSize(width: w, height: 24)
    }

    open override func layout() {
        super.layout()
        fill.frame = bounds
        ring.frame = bounds.insetBy(dx: -3, dy: -3)
        let midY = bounds.height / 2
        var x: CGFloat = 8
        if glyphViews.count == 1 {
            glyphViews[0].frame = NSRect(x: interactive ? x - 2 : x, y: midY - 6, width: 12, height: 12)
        } else {
            for (i, g) in glyphViews.enumerated() { g.frame = NSRect(x: x + CGFloat(i) * 14, y: midY - 6, width: 12, height: 12) }
        }
        if !glyphViews.isEmpty { x += glyphAdvance + 4 }
        let room = max(0, bounds.width - x - (interactive ? 4 + 8 + 8 : 8))
        let frame = NSRect(x: x, y: midY - 8, width: min(labelWidth, room), height: 16)
        label.frame = frame
        middle.frame = frame
        chevron.frame = NSRect(x: frame.maxX + (plainChevron ? 2 : 4), y: midY - 6, width: 12, height: 12)
    }

    open override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    open override func updateLayer() {
        fill.backgroundColor = interactive && state.hoverOrPressed ? Themed.color(\.accent).cgColor(in: self) : nil
        ring.isHidden = !(interactive && state.focusVisible)
        ring.borderColor = Themed.color(\.ring).cgColor(in: self)
    }

    private func restyle() {
        let color = interactive && state.hovered ? Themed.color(\.contrastForeground, 0.8) : Themed.color(\.contrastMutedForeground, 0.7)
        label.color = color
        middle.color = color
        glyphViews.forEach { $0.strokeColor = color }
        chevron.strokeColor = color
        needsDisplay = true
    }

    open override func resetCursorRects() {
        if interactive { super.resetCursorRects() }
    }

    open override func performAction() {
        guard interactive else { return }
        super.performAction()
    }
}

/// `BranchToolbarEnvironmentSelector` (BranchToolbarEnvironmentSelector.tsx:29-139): the machine glyph and the
/// environment label, with the label in a tooltip. Locked (or with one machine) it is the static row.
public final class RunOnControl: ComposerContextControl {
    public var options: [RunOnOption] = [] { didSet { if options != oldValue { refresh() } } }
    public var selectedId: String? { didSet { if selectedId != oldValue { refresh() } } }
    /// `envLocked`, or nothing to choose between: the static label.
    public var locked = false { didSet { if locked != oldValue { refresh() } } }
    public var onChange: (@MainActor (String) -> Void)?
    public var offersAutoBalance = false
    public var autoBalanceLabel: String? { didSet { refresh() } }
    public var onAutoBalance: (@MainActor () -> Void)?
    public func autoBalanceMenuItem() -> MenuItem? {
        guard offersAutoBalance else { return nil }
        var item = MenuItem.radio("Auto balance", checked: autoBalanceLabel != nil)
        item.action = { [weak self] in self?.onAutoBalance?() }
        return item
    }
    private(set) var openList: MenuPopupView?

    public override init() {
        super.init()
        setAccessibilityLabel("Run on")
        refresh()
    }

    public var selected: RunOnOption? { options.first { $0.environmentId == selectedId } }

    private func refresh() {
        glyphs = [EnvironmentMachineIcon.definition(selected?.machine ?? "server")]
        text = autoBalanceLabel ?? selected?.label ?? "Run on"
        interactive = !locked && options.count > 1
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
        if let item = autoBalanceMenuItem() { items.append(item) }
        for option in options {
            var item = MenuItem(option.label, kind: .radio(autoBalanceLabel == nil && option.environmentId == selectedId))
            item.glyph = EnvironmentMachineIcon.definition(option.machine)
            item.extraBottom = 1
            item.action = { [weak self] in
                guard let self, option.environmentId != selectedId || autoBalanceLabel != nil else { return }
                onChange?(option.environmentId)
            }
            items.append(item)
        }
        return items
    }
}
