import AppKit

/// T3's `Group` / `ButtonGroup` (`apps/web/src/components/ui/group.tsx`), horizontal: buttons joined edge to edge,
/// inner radii and inner borders removed, optional 1px `GroupSeparator`s between them.
/// Spec: docs/research/recovered/ui-components-b.md section 14.
// ponytail: horizontal button groups only, no focus z-raise; add vertical and input/select members when a screen needs them
public final class GroupView: DSView {
    public var buttons: [ButtonView] { didSet { rebuild(old: oldValue) } }
    public var separators: Bool { didSet { rebuild(old: buttons) } }
    private var separatorViews: [GroupSeparatorView] = []

    public init(buttons: [ButtonView], separators: Bool = false) {
        self.buttons = buttons
        self.separators = separators
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        rebuild(old: [])
    }

    private func rebuild(old: [ButtonView]) {
        old.forEach { $0.removeFromSuperview() }
        separatorViews.forEach { $0.removeFromSuperview() }
        separatorViews = separators ? (1..<max(1, buttons.count)).map { _ in GroupSeparatorView() } : []
        for (i, b) in buttons.enumerated() {
            b.joinedSides = (leading: i > 0, trailing: i < buttons.count - 1)
            addSubview(b)
        }
        // `z-2`: separators paint over the buttons.
        separatorViews.forEach { addSubview($0) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    public override var intrinsicContentSize: NSSize {
        let sizes = buttons.map(\.intrinsicContentSize)
        return NSSize(width: sizes.reduce(0) { $0 + $1.width } + CGFloat(separatorViews.count),
                      height: sizes.map(\.height).max() ?? 0)
    }

    public override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (i, b) in buttons.enumerated() {
            if i > 0, i - 1 < separatorViews.count {
                separatorViews[i - 1].frame = NSRect(x: x, y: 0, width: 1, height: bounds.height)
                x += 1
            }
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x, y: 0, width: s.width, height: bounds.height)
            x += s.width
        }
    }
}

/// `GroupSeparator`: 1px of `--input`; in dark mode a before layer of input/32 sits on it.
final class GroupSeparatorView: DSView {
    override func updateLayer() {
        let base = Themed.color(\.contrastInput).cgColor(in: self)
        guard effectiveAppearance.isDark else { layer?.backgroundColor = base; return }
        // white 8% under white 8% * 32%: composite alpha 1 - (1 - .08)(1 - .0256).
        let overlay = Themed.color(\.contrastInput, 0.32).cgColor(in: self)
        let a1 = base.alpha, a2 = overlay.alpha
        let alpha = a1 + a2 * (1 - a1)
        layer?.backgroundColor = base.copy(alpha: alpha)
    }
}
