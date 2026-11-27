import AppKit
import DesignSystem

/// Redesign's machine and workspace row under the composer, after Capy's (2026-10-22): a quiet control since
/// 2026-11-26 (`DitherPill.quietPatch`, the user: "not everything has to be pills"), a 14pt machine glyph, "machine · Worktree" in 13pt text, the
/// disconnected machine's status dot and a small up chevron, with the chips' hover fill and brighter text on hover
/// and while its menu is open. It takes the place of the checkout and ref pills; its menu holds the machine, the workspace and
/// the ref (`GitController.openDeviceMenu`).
public final class DitherDeviceRowView: ControlView {
    private var icon = IconView(name: .laptop, size: 14)
    private let label = LabelView()
    private var chevron = IconView(name: .chevronUp, size: 12)
    private let dot = CALayer()
    private let pill = DitherPillSurface()
    private let fill = CALayer()
    private var kind = "laptop"

    /// Sets the row; only a known disconnected machine shows the dot.
    public func configure(machine: String, kind: String, workspace: String?, online: Bool?) {
        let text = [machine, workspace].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        if self.kind != kind {
            self.kind = kind
            icon.removeFromSuperview()
            icon = IconView(definition: EnvironmentMachineIcon.definition(kind), size: 14)
            addSubview(icon)
            needsLayout = true
        }
        guard text != label.text || online != self.online else { restyle(); return }
        label.text = text
        self.online = online
        setAccessibilityValue(text)
        invalidateIntrinsicContentSize()
        restyle()
        needsLayout = true
        superview?.needsLayout = true
    }
    private(set) var online: Bool?
    private var showsStatusDot: Bool { online == false }
    var text: String { label.text }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        scalesWhenPressed = false
        for l in [fill, dot] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()] }
        fill.cornerRadius = DitherPill.radius
        dot.cornerRadius = RedesignTokens.Radius.capsule(6)
        layer?.masksToBounds = false
        addSubview(pill)
        layer?.addSublayer(fill)
        layer?.addSublayer(dot)
        label.font = DSFont.ui(13)
        label.lineHeight = 16
        for v in [icon, label, chevron] as [NSView] { addSubview(v) }
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Machine and workspace")
        restyle()
    }

    private var textWidth: CGFloat { min(280, ceil(label.textWidth)) }

    public override var intrinsicContentSize: NSSize {
        var w = Self.pad + 14 + 6 + textWidth
        if showsStatusDot { w += 6 + 6 }
        return NSSize(width: w + 6 + 12 + Self.pad, height: DitherPill.height)
    }

    /// Space between the pill's edges and the glyph on the left, the chevron on the right: the chips' (`DitherPill.pad`).
    private static let pad = DitherPill.pad

    /// A quiet control (`DitherPill.quietPatch`): beside the project chip on the new-thread page, and under a thread's
    /// composer.
    public var quiet = false { didSet { if quiet != oldValue { pill.quiet = quiet; restyle(); needsLayout = true } } }

    /// On the new-thread page the row sits above the composer beside the project chip, and its menu opens downward
    /// like the chip's, so its chevron points down.
    public var opensDown = false {
        didSet {
            guard opensDown != oldValue else { return }
            chevron.removeFromSuperview()
            chevron = IconView(name: opensDown ? .chevronDown : .chevronUp, size: 12)
            addSubview(chevron)
            restyle()
            needsLayout = true
        }
    }

    public override func layout() {
        super.layout()
        let midY = bounds.height / 2
        pill.frame = bounds
        icon.frame = NSRect(x: Self.pad, y: midY - 7, width: 14, height: 14)
        // Narrow rows give the text what is left after the dot and chevron.
        let tail: CGFloat = (showsStatusDot ? 12 : 0) + 6 + 12 + Self.pad
        let textX = Self.pad + 14 + 6
        label.frame = NSRect(x: textX, y: midY - 8, width: max(0, min(textWidth, bounds.width - textX - tail)), height: 16)
        var x = label.frame.maxX
        CATransaction.begin(); CATransaction.setDisableActions(true)
        DitherPill.placeFill(fill, in: bounds, quiet: quiet)
        dot.isHidden = !showsStatusDot
        if showsStatusDot {
            dot.frame = CGRect(x: x + 6, y: midY - 3, width: 6, height: 6)
            x += 12
        }
        CATransaction.commit()
        chevron.frame = NSRect(x: x + 6, y: midY - 6, width: 12, height: 12)
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
        fill.backgroundColor = state.hoverOrPressed ? RedesignTokens.State.fill(state, dark: effectiveAppearance.isDark)?.cgColor : nil
        dot.backgroundColor = Themed.color(\.secondaryLabel).cgColor(in: self)
    }

    private func restyle() {
        let lit = state.hoverOrPressed
        let rest = quiet ? Themed.color(\.foreground, RedesignTokens.Text.quiet) : Themed.color(\.mutedForeground)
        label.color = lit ? Themed.color(\.foreground) : rest
        icon.strokeColor = lit ? Themed.color(\.foreground, 0.85) : rest
        chevron.strokeColor = lit ? Themed.color(\.foreground, 0.85) : rest
        needsDisplay = true
    }
}
