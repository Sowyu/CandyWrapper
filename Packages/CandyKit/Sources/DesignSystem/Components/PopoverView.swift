import AppKit

/// T3's `PopoverPopup` (`popover.tsx`): any content on the glass surface. Desktop values.
/// Spec: docs/research/recovered/ui-components-a.md section 14.
public final class PopoverView: DSView, PopupContent {
    public enum Padding: Sendable {
        /// `card` is `p-3`, for cards that are not `PopoverPopup`, like the minimap preview.
        case `default`, compact, card, none
        /// Vertical, horizontal.
        var insets: (v: CGFloat, h: CGFloat) {
            switch self { case .default: (16, 16); case .compact: (8, 12); case .card: (12, 12); case .none: (0, 0) }
        }
    }
    public enum Width: Sendable {
        case auto, sm, md, lg
        var points: CGFloat? { switch self { case .auto: nil; case .sm: 256; case .md: 320; case .lg: 384 } }
    }

    public let content: NSView
    public let padding: Padding
    public let width: Width
    private let beforeLine: Bool
    private let tooltipStyle: Bool
    private let surface: PopupSurface
    private let cornerRadius: CGFloat?
    private let decoration = BoxDecorationLayer()
    private let dropShadow = PopupShadowLayer()
    /// Keys for the content first (an editor's Enter and Escape); true when used.
    public var onKey: (@MainActor (PopupKey) -> Bool)?
    public func popupHandleKey(_ key: PopupKey) -> Bool { onKey?(key) ?? false }

    /// `beforeLine` false is `before:hidden` (the model picker, Select popups). `tooltipStyle` is
    /// `PopoverPopup tooltipStyle` (popover.tsx:89-90): `rounded-md` and `shadow-md/5` in place of the deep shadow.
    /// `surface` and `radius` style a plain glass card instead, like `dropdown-glass rounded-xl shadow-xl`.
    public init(content: NSView, padding: Padding = .default, width: Width = .auto, beforeLine: Bool = true, tooltipStyle: Bool = false,
                surface: PopupSurface = .glass, radius: CGFloat? = nil) {
        self.content = content
        self.padding = padding
        self.width = width
        self.beforeLine = beforeLine
        self.tooltipStyle = tooltipStyle
        self.surface = surface
        self.cornerRadius = radius
        super.init(frame: .zero)
        decoration.host = self
        dropShadow.host = self
        layer?.addSublayer(dropShadow)
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        applySurface()
        addSubview(content)
    }

    private func applySurface() {
        let radius = DesignGeometry.radius(cornerRadius ?? (tooltipStyle ? 8 : 10), in: self)
        let look = surface.split(radius: radius, beforeLine: beforeLine)
        decoration.boxStyle = look.box
        dropShadow.radius = radius
        dropShadow.shadows = tooltipStyle
            ? [BoxShadow(y: 4, blur: 6, spread: -1, color: Themed.black(0.05)), BoxShadow(y: 2, blur: 4, spread: -2, color: Themed.black(0.05))]
            : look.shadows
    }

    public var frostRadius: CGFloat { DesignGeometry.radius(cornerRadius ?? (tooltipStyle ? 8 : 10), in: self) }

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
        applySurface()
    }

    /// Opens under `trigger`: bottom, center, 4px, scale .98 and fade in over 150ms, and the same out (T3 3105 f570294df).
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
