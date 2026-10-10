import AppKit

/// T3's `PopoverPopup` (`popover.tsx`): any content on the glass surface. Desktop values.
/// Spec: docs/research/recovered/ui-components-a.md section 14.
public final class PopoverView: DSView, PopupContent {
    public enum Padding: Sendable {
        case `default`, compact, none
        /// Vertical, horizontal.
        var insets: (v: CGFloat, h: CGFloat) {
            switch self { case .default: (16, 16); case .compact: (8, 12); case .none: (0, 0) }
        }
    }
    public enum Width: Sendable {
        case auto, sm, md, lg
        var points: CGFloat? { switch self { case .auto: nil; case .sm: 256; case .md: 320; case .lg: 384 } }
    }

    public let content: NSView
    public let padding: Padding
    public let width: Width
    private let decoration = BoxDecorationLayer()
    private let dropShadow = PopupShadowLayer()

    /// `beforeLine` false is `before:hidden` (the model picker, Select popups).
    public init(content: NSView, padding: Padding = .default, width: Width = .auto, beforeLine: Bool = true) {
        self.content = content
        self.padding = padding
        self.width = width
        super.init(frame: .zero)
        decoration.host = self
        dropShadow.host = self
        layer?.addSublayer(dropShadow)
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        let look = PopupSurface.glass.split(radius: 10, beforeLine: beforeLine)
        decoration.boxStyle = look.box
        dropShadow.radius = 10
        dropShadow.shadows = look.shadows
        addSubview(content)
    }

    public override var intrinsicContentSize: NSSize {
        let i = padding.insets
        let c = content.fittingSize
        let w = width.points ?? (c.width + 2 * i.h + 2)
        return NSSize(width: w, height: c.height + 2 * i.v + 2)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        dropShadow.update(boxSize: bounds.size)
        let i = padding.insets
        content.frame = bounds.insetBy(dx: 1 + i.h, dy: 1 + i.v)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        dropShadow.update(boxSize: bounds.size)
    }

    /// Opens under `trigger`: bottom, center, 4px, scale .98 and fade in over 150ms, no exit motion.
    @discardableResult
    public func show(from trigger: NSView, placement: PopupPlacement = .popover) -> OpenPopup? {
        trigger.popupHost?.open(self, trigger: trigger, placement: placement, motion: .popover)
    }
}

/// A popover title: `font-semibold text-sm leading-none`.
@MainActor public func popoverTitle(_ text: String) -> LabelView {
    let label = LabelView(text, font: DSFont.ui(14, weight: .semibold), color: PopupSurface.text)
    label.lineHeight = 14
    return label
}
