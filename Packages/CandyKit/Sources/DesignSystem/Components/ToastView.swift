import AppKit
import QuartzCore

/// One stacked toast (`toast.tsx:578-690`), inline layout: type icon and title, description below,
/// an optional `xs` action button on the right, and the close orb on the top-right corner.
/// Width comes from the frame (T3: 360); `height(forWidth:)` gives the natural height.
/// ponytail: no copy-error button, expandable details or stacked-end action layout; add them with the thread toasts that use them
public final class ToastView: DSView {
    public let kind: ToastQueue.Kind
    public var id = 0
    /// Content opacity for toasts behind the front one in a collapsed stack (250ms fade).
    var contentHidden = false {
        didSet {
            guard contentHidden != oldValue else { return }
            Motion.reduced ? (content.layer?.opacity = contentHidden ? 0 : 1)
                : Motion.animate(content.layer!, keyPath: "opacity", to: contentHidden ? 0 : 1, duration: 0.25)
            content.layer?.opacity = contentHidden ? 0 : 1
        }
    }
    var onDismiss: (@MainActor () -> Void)? {
        get { closeOrb.action }
        set { closeOrb.action = newValue }
    }
    /// Swipe: (dx, dy) while dragging, and the release.
    var onSwipe: (@MainActor (CGPoint, _ ended: Bool) -> Void)?

    private let decoration = BoxDecorationLayer()
    private let content = DSView()
    private let titleText = TextBlockView()
    private let messageText = TextBlockView()
    private let iconView: IconView?
    private let actionButton: ButtonView?
    private let closeOrb = ToastCloseOrb()

    /// `data.leadingIcon` (toast.tsx:343-349): replaces the type icon, in its own color (the thread notification toasts).
    private let leadingIconColor: NSColor?

    public init(title: String, message: String? = nil, kind: ToastQueue.Kind = .plain, actionTitle: String? = nil,
                action: (@MainActor () -> Void)? = nil, leadingIcon: (name: IconName, color: NSColor)? = nil) {
        self.kind = kind
        leadingIconColor = leadingIcon?.color
        let typeIcon: IconName? = switch kind {
        case .error: .circleAlert
        case .info: .info
        case .success: .circleCheck
        case .warning: .triangleAlert
        case .plain, .loading: nil
        }
        let icon = leadingIcon?.name ?? typeIcon
        // ponytail: loading shows no spinner yet; use SpinnerView at 80% opacity when a loading toast exists
        iconView = icon.map { IconView(name: $0) }
        actionButton = actionTitle.map { ButtonView($0, variant: .default, size: .xs) }
        actionButton?.action = action
        super.init(frame: .zero)
        layer?.masksToBounds = false
        decoration.host = self
        decoration.outset = 48 // shadow-xl reaches 20 + 25px down
        layer?.addSublayer(decoration)
        titleText.text = title
        titleText.font = DSFont.ui(14, weight: .medium)
        titleText.lineHeight = 20
        messageText.text = message ?? ""
        messageText.font = DSFont.ui(14)
        messageText.lineHeight = 20
        addSubview(content)
        [titleText, messageText].forEach(content.addSubview)
        iconView.map(content.addSubview)
        actionButton.map(content.addSubview)
        addSubview(closeOrb)
        closeOrb.setAccessibilityLabel("Dismiss notification")
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("dialog")
        setAccessibilityLabel(title)
        restyle()
    }

    private var hasMessage: Bool { !messageText.text.isEmpty }

    /// `toastManager.update` for text only: a progress toast changes in place.
    public func setText(title: String, message: String?) {
        guard titleText.text != title || messageText.text != (message ?? "") else { return }
        titleText.text = title
        messageText.text = message ?? ""
        messageText.isHidden = message == nil
        setAccessibilityLabel(title)
        needsLayout = true
    }

    private struct Frames { var icon = CGRect.zero, title = CGRect.zero, message = CGRect.zero, action = CGRect.zero, height: CGFloat = 0 }

    /// Inline content: `py-3 pl-3.5`, `pr-6` with an action or `pr-10` without, `gap-1.5`, items centered.
    private func frames(width: CGFloat) -> Frames {
        var f = Frames()
        let actionSize = actionButton?.intrinsicContentSize ?? .zero
        let left: CGFloat = 1 + 14
        let right = width - 1 - (actionButton == nil ? 40 : 24 + actionSize.width + 6)
        let textX = left + (iconView == nil ? 0 : 16 + 8)
        let titleHeight = titleText.height(forWidth: right - textX)
        let messageHeight = hasMessage ? messageText.height(forWidth: right - left) : 0
        let column = titleHeight + (hasMessage ? 2 + messageHeight : 0)
        let row = max(column, actionSize.height)
        let top: CGFloat = 1 + 12
        let columnTop = top + (row - column) / 2
        f.icon = CGRect(x: left, y: columnTop + 2, width: 16, height: 16)
        f.title = CGRect(x: textX, y: columnTop, width: right - textX, height: titleHeight)
        f.message = CGRect(x: left, y: columnTop + titleHeight + 2, width: right - left, height: messageHeight)
        f.action = CGRect(x: right + 6, y: top + (row - actionSize.height) / 2, width: actionSize.width, height: actionSize.height)
        f.height = top + row + 12 + 1
        return f
    }

    public func height(forWidth width: CGFloat) -> CGFloat { frames(width: width).height }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        content.frame = bounds
        let f = frames(width: bounds.width)
        iconView?.frame = f.icon
        titleText.frame = f.title
        messageText.frame = f.message
        actionButton?.frame = f.action
        // `absolute -top-1.5 -right-1.5`, 24px.
        closeOrb.frame = NSRect(x: bounds.width + 6 - 24, y: -6, width: 24, height: 24)
    }

    public override func updateLayer() { restyle() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 10
        // ponytail: `dropdown-glass` is popover at 83.6% blurred over whatever is behind; drawn as that alpha over
        // --background, which is what it gives over a plain window. Real blur if toasts sit over busy content.
        box.fill = Themed.color(\.popover).blended(over: Themed.color(\.background), alpha: 0.836)
        box.border = Themed.color(\.contrastForeground, 0.1)
        box.shadows = [BoxShadow(y: 20, blur: 25, spread: -5, color: Themed.black(0.25)),
                       BoxShadow(y: 8, blur: 10, spread: -6, color: Themed.black(0.25))]
        decoration.boxStyle = box
        titleText.color = Themed.color(\.contrastPopoverForeground)
        messageText.color = Themed.color(\.contrastMutedForeground)
        let typeColor: NSColor = switch kind {
        case .error: Themed.color(\.destructive)
        case .info: Themed.color(\.info)
        case .success: Themed.color(\.success)
        case .warning: Themed.color(\.warning)
        case .plain, .loading: Themed.color(\.contrastPopoverForeground)
        }
        iconView?.strokeColor = leadingIconColor ?? typeColor
    }

    /// Hit testing through the stack transform (`sublayerTransform`), so translated and scaled toasts get their clicks.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let t = layer?.sublayerTransform, !CATransform3DIsIdentity(t), let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let p = CGPoint(x: local.x, y: local.y).applying(CATransform3DGetAffineTransform(t).inverted())
        guard bounds.contains(p) else { return nil }
        return super.hitTest(convert(p, to: superview))
    }

    // MARK: Swipe

    private var dragStart: CGPoint?

    public override func mouseDown(with event: NSEvent) { dragStart = event.locationInWindow }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = event.locationInWindow
        onSwipe?(CGPoint(x: p.x - start.x, y: start.y - p.y), false) // window y is up; CSS y is down
    }

    public override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        let p = event.locationInWindow
        onSwipe?(CGPoint(x: p.x - start.x, y: start.y - p.y), true)
    }
}

/// The toast's dismiss orb: a 24px circle, `border-border/60 bg-popover/92 shadow-sm`, 12px X in
/// muted-foreground; hover makes the fill solid and the X foreground.
final class ToastCloseOrb: ControlView {
    private let decoration = BoxDecorationLayer()
    private let icon = IconView(name: .x, size: 12)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        addSubview(icon)
        restyle()
    }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        icon.frame = NSRect(x: 6, y: 6, width: 12, height: 12)
    }

    override func stateDidChange(from old: State) { restyle() }
    override func updateLayer() { restyle() }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 12
        box.border = Themed.color(\.border, 0.6)
        box.fill = Themed.color(\.popover, state.hovered ? 1 : 0.92)
        box.shadows = [BoxShadow(y: 1, blur: 3, color: Themed.black(0.1)), BoxShadow(y: 1, blur: 2, spread: -1, color: Themed.black(0.1))]
        if state.focusVisible { box.shadows = BoxShadow.focusRing(ring: Themed.color(\.ring), offset: Themed.color(\.background)) + box.shadows }
        decoration.boxStyle = box
        icon.strokeColor = Themed.color(state.hovered ? \.foreground : \.mutedForeground)
    }
}

extension NSColor {
    /// `self` at `alpha` composited over `base`, per appearance (for solid glass substitutes).
    func blended(over base: NSColor, alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = base
            appearance.performAsCurrentDrawingAppearance {
                let top = self.usingColorSpace(.sRGB) ?? self, bottom = base.usingColorSpace(.sRGB) ?? base
                let a = alpha * top.alphaComponent
                result = NSColor(srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
                                 green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                                 blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1)
            }
            return result
        }
    }
}
