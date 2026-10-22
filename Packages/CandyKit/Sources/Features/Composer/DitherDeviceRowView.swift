import AppKit
import DesignSystem

/// Redesign's machine and workspace row under the composer, after Capy's (2026-10-22): no pill, a 14pt machine glyph,
/// "machine · Worktree" in muted 13pt text, the machine's status dot and a small up chevron, brighter on hover and while
/// its menu is open. It takes the place of the checkout and ref pills; its menu holds the machine, the workspace and
/// the ref (`GitController.openDeviceMenu`).
public final class DitherDeviceRowView: ControlView {
    private var icon = IconView(name: .laptop, size: 14)
    private let label = LabelView()
    private let chevron = IconView(name: .chevronUp, size: 12)
    private let dot = CALayer()
    private var kind = "laptop"

    /// Sets the row; nil `online` hides the dot.
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
    var text: String { label.text }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        scalesWhenPressed = false
        dot.cornerRadius = 3
        dot.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(dot)
        label.font = DSFont.ui(13)
        label.lineHeight = 16
        label.halo = true
        for v in [icon, label, chevron] as [NSView] { addSubview(v) }
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Machine and workspace")
        restyle()
    }

    private var textWidth: CGFloat { min(280, ceil(label.textWidth)) }

    public override var intrinsicContentSize: NSSize {
        var w = 4 + 14 + 6 + textWidth
        if online != nil { w += 6 + 6 }
        return NSSize(width: w + 6 + 12 + 4, height: DitherPill.height)
    }

    public override func layout() {
        super.layout()
        let midY = bounds.height / 2
        icon.frame = NSRect(x: 4, y: midY - 7, width: 14, height: 14)
        // Narrow rows give the text what is left after the dot and chevron.
        let tail: CGFloat = (online != nil ? 12 : 0) + 6 + 12 + 4
        label.frame = NSRect(x: 24, y: midY - 8, width: max(0, min(textWidth, bounds.width - 24 - tail)), height: 16)
        var x = label.frame.maxX
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.isHidden = online == nil
        if online != nil {
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
        dot.backgroundColor = (online == true ? Themed.color(\.success) : Themed.color(\.secondaryLabel)).cgColor(in: self)
    }

    private func restyle() {
        let lit = state.hoverOrPressed
        label.color = lit ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        icon.strokeColor = lit ? Themed.color(\.foreground, 0.85) : Themed.color(\.mutedForeground)
        chevron.strokeColor = lit ? Themed.color(\.foreground, 0.85) : Themed.color(\.mutedForeground)
        // The label's halo for the glyphs too, so they read over bright or dark art alike.
        let dark = effectiveAppearance.isDark
        let glow = Themed.color(\.background).cgColor(in: self)
        for v in [icon, chevron] as [NSView] {
            v.wantsLayer = true
            v.layer?.shadowColor = glow
            v.layer?.shadowOpacity = ThemeRuntime.isDither(dark: dark) ? 1 : 0
            v.layer?.shadowRadius = 2
            v.layer?.shadowOffset = .zero
        }
        needsDisplay = true
    }
}
