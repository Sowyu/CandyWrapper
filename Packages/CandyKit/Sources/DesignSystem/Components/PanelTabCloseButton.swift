import AppKit

/// T3's `PanelTabCloseButton` (`apps/web/src/components/ui/panel-tab-close-button.tsx`): a 16px button that
/// shows the tab's identity glyph and swaps it for an X while the tab row is hovered or the button has
/// keyboard focus. Spec: docs/research/recovered/ui-components-b.md section 24.
public final class PanelTabCloseButton: ControlView {
    /// `group-hover/tab`: the owning tab row sets this from its own hover.
    public var isTabHovered = false { didSet { if isTabHovered != oldValue { restyle() } } }

    private let decoration = BoxDecorationLayer()
    private let identity: NSView
    private let close = IconView(name: .x, size: 12)

    /// `identity` is the 12px glyph shown at rest (`size-3`).
    public init(identity: NSView, label: String = "Close") {
        self.identity = identity
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        scalesWhenPressed = false
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        addSubview(identity)
        addSubview(close)
        setAccessibilityLabel(label)
        restyle()
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        identity.frame = NSRect(x: 2, y: 2, width: 12, height: 12)
        close.frame = identity.frame
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 6 // rounded-sm
        if state.hovered { box.fill = Themed.color(\.muted) }
        decoration.boxStyle = box
        let showClose = isTabHovered || state.focusVisible
        identity.isHidden = showClose
        close.isHidden = !showClose
        close.strokeColor = Themed.color(\.contrastForeground)
    }
}
