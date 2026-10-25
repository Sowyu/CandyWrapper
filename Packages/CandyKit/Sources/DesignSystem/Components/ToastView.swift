import AppKit
import QuartzCore

/// One stacked toast (`toast.tsx:578-690`), inline layout: type icon and title, description below,
/// an optional `xs` action button on the right, and the close orb on the top-right corner.
/// Width comes from the frame (T3: 360); `height(forWidth:)` gives the natural height.
/// ponytail: no copy-error button; add it with the thread toasts that use it
public final class ToastView: DSView {
    public var onDidDismiss: (() -> Void)?
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
    private let secondaryButton: ButtonView?
    /// `actionVariant` and `data.secondaryActionVariant` (toast.tsx): `outline` on the stacked thread toasts.
    public func setActionVariants(_ primary: ButtonView.Variant, secondary: ButtonView.Variant? = nil) {
        actionButton?.variant = primary
        if let secondary { secondaryButton?.variant = secondary }
    }
    /// `actionProps.disabled`.
    public var isActionEnabled: Bool {
        get { actionButton?.isEnabled ?? false }
        set { actionButton?.isEnabled = newValue }
    }
    private let stackedActions: Bool
    private let closeOrb = ToastCloseOrb()

    /// `expandableContent` with `expandableDescriptionTrigger` (toast.tsx:176-258): the description toggles a list
    /// under it (labels in the tooltip, a chevron at its end); the list scrolls past 160pt (`max-h-40`).
    public var details: (expand: String, collapse: String, items: [ToastDetailListView.Item])? {
        didSet {
            detailList.items = details?.items ?? []
            if details == nil { expanded = false }
            chevron.isHidden = details == nil || expanded
            chevronOpen.isHidden = details == nil || !expanded
            updateDetailsTooltip()
            needsLayout = true
            onHeightChange?()
        }
    }
    private var expanded = false
    /// A button inside the description, on its own row at the end (`mt-2 flex justify-end`), such as
    /// KeybindingsConfigWarning.tsx:28-52's "Open keybindings.json".
    public var descriptionButton: ButtonView? {
        didSet { oldValue?.removeFromSuperview(); descriptionButton.map(content.addSubview); needsLayout = true; onHeightChange?() }
    }
    /// A link that flows inline after the description's last word (`ml-2 inline`), such as the update toast's
    /// "Read more" (desktopUpdate.toast.tsx:24-47). It wraps to its own line when the last line is full.
    public func setMessageLink(_ title: String, action: @escaping @MainActor () -> Void) {
        messageLink?.removeFromSuperview()
        let link = ToastInlineLinkView(title)
        link.action = action
        content.addSubview(link)
        messageLink = link
        needsLayout = true
        onHeightChange?()
    }
    private var messageLink: ToastInlineLinkView?
    private let chevron = IconView(name: .chevronDown, size: 14)
    private let chevronOpen = IconView(name: .chevronUp, size: 14)
    private let detailList = ToastDetailListView()
    private lazy var detailScroll = ScrollAreaView(documentView: detailList, scrollbars: .native) // toast.tsx:142
    /// The natural height changed (details opened or closed); the viewport lays the stack out again.
    var onHeightChange: (@MainActor () -> Void)?

    private func updateDetailsTooltip() {
        messageText.toolTip = details.map { expanded ? $0.collapse : $0.expand }
        setAccessibilityHelp(messageText.toolTip)
    }

    /// Opens or closes the details as a click on the description does.
    public func toggleDetailsForTesting() { toggleDetails() }

    private func toggleDetails() {
        guard details != nil else { return }
        expanded.toggle()
        chevron.isHidden = expanded
        chevronOpen.isHidden = !expanded
        if expanded, detailScroll.superview == nil { content.addSubview(detailScroll) }
        detailScroll.isHidden = !expanded
        updateDetailsTooltip()
        needsLayout = true
        onHeightChange?()
    }

    /// `data.leadingIcon` (toast.tsx:343-349): replaces the type icon, in its own color (the thread notification toasts).
    private let leadingIconColor: NSColor?

    public init(title: String, message: String? = nil, kind: ToastQueue.Kind = .plain, actionTitle: String? = nil,
                action: (@MainActor () -> Void)? = nil, secondaryTitle: String? = nil, secondaryAction: (@MainActor () -> Void)? = nil, leadingIcon: (name: IconName, color: NSColor)? = nil) {
        self.kind = kind
        stackedActions = secondaryTitle != nil
        secondaryButton = secondaryTitle.map { ButtonView($0, variant: .ghost, size: .xs) }
        secondaryButton?.action = secondaryAction
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
        // A leading Claude glyph names the provider (an update, a migration), so Dither draws Anthropic's mark.
        iconView = icon.map { IconView(name: $0, providerMark: leadingIcon != nil) }
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
        secondaryButton.map(content.addSubview)
        chevron.isHidden = true
        chevronOpen.isHidden = true
        content.addSubview(chevron)
        content.addSubview(chevronOpen)
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

    private struct Frames {
        var icon = CGRect.zero, title = CGRect.zero, message = CGRect.zero, action = CGRect.zero, secondary = CGRect.zero
        var chevron = CGRect.zero, details = CGRect.zero, descriptionButton = CGRect.zero, messageLink = CGRect.zero
        var height: CGFloat = 0
    }

    /// Inline content: `py-3 pl-3.5`, `pr-6` with an action or `pr-3.5` without, `gap-1.5`, items centered. Without
    /// an action only the title row keeps `pr-6` clear of the close button (toast.tsx:288,330-337, T3 e54e71d725).
    private func frames(width: CGFloat) -> Frames {
        var f = Frames()
        let actionSize = actionButton?.intrinsicContentSize ?? .zero
        let left: CGFloat = 1 + 14
        if stackedActions {
            let right = width - left
            let textX = left + (iconView == nil ? 0 : 24)
            let th = titleText.height(forWidth: max(1, right - textX))
            let mh = hasMessage ? messageText.height(forWidth: max(1, right - left)) : 0
            let top: CGFloat = 11
            f.icon = CGRect(x: left, y: top + 2, width: 16, height: 16)
            f.title = CGRect(x: textX, y: top, width: right - textX, height: th)
            f.message = CGRect(x: left, y: top + th + 2, width: right - left, height: mh)
            let y = top + th + (hasMessage ? mh + 2 : 0) + 8
            f.action = CGRect(x: right - actionSize.width, y: y, width: actionSize.width, height: actionSize.height)
            let secondary = secondaryButton?.intrinsicContentSize ?? .zero
            f.secondary = CGRect(x: f.action.minX - 6 - secondary.width, y: y, width: secondary.width, height: secondary.height)
            f.height = y + max(actionSize.height, secondary.height) + 11
            return f
        }
        let right = width - 1 - (actionButton == nil ? 14 : 24 + actionSize.width + 6)
        let titleRight = actionButton == nil ? right - 24 : right
        let textX = left + (iconView == nil ? 0 : 16 + 8)
        let titleHeight = titleText.height(forWidth: titleRight - textX)
        // With details the description shares its row with the chevron (`gap-1.5`, `size-3.5`).
        let messageRight = details == nil ? right : right - 6 - 14
        var messageHeight = hasMessage ? messageText.height(forWidth: messageRight - left) : 0
        if let messageLink, hasMessage {
            let lines = messageText.layout(forWidth: messageRight - left)
            let last = lines.widths.last ?? 0
            let w = messageLink.intrinsicContentSize.width
            let fits = last + 8 + w <= messageRight - left
            if !fits { messageHeight += 20 }
            f.messageLink = CGRect(x: fits ? left + ceil(last) + 8 : left, y: CGFloat(fits ? lines.lines.count - 1 : lines.lines.count) * 20,
                                   width: w, height: 20)
        }
        // `mt-2 max-h-40` under the description while open, after the body column's `gap-0.5`.
        let detailsHeight = expanded ? min(160, detailList.height(forWidth: right - left - 2)) : 0
        let buttonSize = descriptionButton?.intrinsicContentSize ?? .zero
        let buttonRow = descriptionButton == nil ? 0 : 8 + buttonSize.height
        let column = titleHeight + (hasMessage ? 2 + messageHeight + buttonRow : 0) + (expanded ? 10 + detailsHeight : 0)
        let row = max(column, actionSize.height)
        let top: CGFloat = 1 + 12
        let columnTop = top + (row - column) / 2
        f.icon = CGRect(x: left, y: columnTop + 2, width: 16, height: 16)
        f.title = CGRect(x: textX, y: columnTop, width: titleRight - textX, height: titleHeight)
        f.message = CGRect(x: left, y: columnTop + titleHeight + 2, width: messageRight - left, height: messageHeight)
        f.messageLink.origin.y += f.message.minY
        f.descriptionButton = CGRect(x: messageRight - buttonSize.width, y: f.message.maxY + 8, width: buttonSize.width, height: buttonSize.height)
        // `size-3.5 h-lh`: centered on the description's first 20pt line (toast.tsx:239-244, T3 26c6df72f8).
        f.chevron = CGRect(x: messageRight + 6, y: f.message.minY + 3, width: 14, height: 14)
        f.details = CGRect(x: left, y: f.message.maxY + buttonRow + 10, width: right - left, height: detailsHeight)
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
        chevron.frame = f.chevron
        chevronOpen.frame = f.chevron
        descriptionButton?.frame = f.descriptionButton
        messageLink?.frame = f.messageLink
        if expanded {
            detailScroll.frame = f.details
            detailList.frame = CGRect(x: 0, y: 0, width: f.details.width - 2, height: detailList.height(forWidth: f.details.width - 2))
        }
        actionButton?.frame = f.action
        secondaryButton?.frame = f.secondary
        // `absolute -top-1.5 -right-1.5`, 24px.
        closeOrb.frame = NSRect(x: bounds.width + 6 - 24, y: -6, width: 24, height: 24)
    }

    public override func updateLayer() { restyle() }


    /// Classic Glass's blur under the frosted pane (`WindowGlass.syncPaneBlur`).
    private var paneBlur: BackdropBlurView?
    private func syncPaneBlur() { paneBlur = WindowGlass.syncPaneBlur(paneBlur, in: self, radius: 10) }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncPaneBlur()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncPaneBlur()
        decoration.setNeedsDisplay()
    }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 10
        // ponytail: `dropdown-glass` is popover at 83.6% blurred over whatever is behind; drawn as that alpha over
        // --background, which is what it gives over a plain window. Real blur if toasts sit over busy content.
        box.fill = WindowGlass.floating(stock: Themed.color(\.popover).blended(over: Themed.color(\.background), alpha: PopupSurface.dropdownGlassAlpha))
        box.border = Themed.color(\.contrastForeground, 0.1)
        box.shadows = [BoxShadow(y: 20, blur: 25, spread: -5, color: Themed.black(0.25)),
                       BoxShadow(y: 8, blur: 10, spread: -6, color: Themed.black(0.25))]
        decoration.boxStyle = box
        titleText.color = Themed.color(\.contrastPopoverForeground)
        messageText.color = Themed.color(\.contrastMutedForeground)
        chevron.strokeColor = Themed.color(\.mutedForeground, 0.8)
        chevronOpen.strokeColor = chevron.strokeColor
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
        // A click (no drag) on the description row opens or closes the details.
        if details != nil, hypot(p.x - start.x, p.y - start.y) < 4 {
            let local = content.convert(event.locationInWindow, from: nil)
            if messageText.frame.union(chevron.frame).insetBy(dx: 0, dy: -2).contains(local) { toggleDetails(); return }
        }
        onSwipe?(CGPoint(x: p.x - start.x, y: start.y - p.y), true)
    }
}

/// The inline description link: 14px muted text, dotted underline 4px under the baseline, then a 12px
/// arrow turned -45deg (`ml-1 inline size-3 -rotate-45`, strokeWidth 2.25); hover turns it foreground.
final class ToastInlineLinkView: ControlView {
    private let label: LabelView
    private let arrow = IconView(name: .arrowRight, size: 12)
    private let underline = CAShapeLayer()

    init(_ title: String) {
        label = LabelView(title, font: DSFont.ui(14))
        super.init(frame: .zero)
        scalesWhenPressed = false
        transitions = .colors
        label.lineHeight = 20
        arrow.strokeWidth = 2.25
        arrow.setRotation(-45, motion: .none)
        addSubview(label)
        addSubview(arrow)
        underline.fillColor = nil
        underline.lineWidth = 1
        underline.lineDashPattern = [1, 1]
        underline.actions = ["path": NSNull(), "strokeColor": NSNull()]
        layer?.addSublayer(underline)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 4 + 12, height: 20) }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        let color = Themed.color(state.hovered ? \.contrastForeground : \.contrastMutedForeground)
        label.color = color
        arrow.strokeColor = color
        underline.strokeColor = color.cgColor(in: self)
    }

    override func layout() {
        super.layout()
        let w = ceil(label.textWidth)
        label.frame = NSRect(x: 0, y: 0, width: w, height: 20)
        // `align-[-0.125em]`: the glyph's bottom sits 1.75px under the baseline.
        arrow.frame = NSRect(x: w + 4, y: 5.5, width: 12, height: 12)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 19.5)); path.addLine(to: CGPoint(x: w, y: 19.5))
        underline.frame = bounds
        underline.path = path
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
        transitions = [.color, .background, .shadow] // transition-[color,background-color,box-shadow] (toast.tsx:100)
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

/// `SlowRequestDetails` (SlowRpcRequestToastCoordinator.tsx:19-35): `space-y-2.5 text-xs`, each row the title in
/// medium foreground and a `text-3xs` detail at 75%, a `border-border/50` rule under all but the last (`pb-2`).
public final class ToastDetailListView: DSView {
    public struct Item: Equatable, Sendable {
        public var title: String, detail: String
        public init(title: String, detail: String) { self.title = title; self.detail = detail }
    }
    public var items: [Item] = [] { didSet { if items != oldValue { rebuild() } } }
    private var rows: [(title: TextBlockView, detail: LabelView, rule: CALayer)] = []

    private func rebuild() {
        rows.forEach { $0.title.removeFromSuperview(); $0.detail.removeFromSuperview(); $0.rule.removeFromSuperlayer() }
        rows = items.map { item in
            let title = TextBlockView()
            title.text = item.title
            title.font = DSFont.ui(12, weight: .medium)
            title.lineHeight = 16
            let detail = LabelView(item.detail, font: DSFont.ui(10))
            detail.lineHeight = 14 // `text-3xs`: 10px on a 14px line
            let rule = CALayer()
            rule.actions = ["position": NSNull(), "bounds": NSNull()]
            addSubview(title); addSubview(detail); layer?.addSublayer(rule)
            return (title, detail, rule)
        }
        needsLayout = true
        needsDisplay = true
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for (i, r) in rows.enumerated() {
            y += r.title.height(forWidth: width) + 2 + 14
            if i < rows.count - 1 { y += 8 + 1 + 10 }
        }
        return y
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (i, r) in rows.enumerated() {
            let h = r.title.height(forWidth: bounds.width)
            r.title.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            r.detail.frame = NSRect(x: 0, y: y + h + 2, width: bounds.width, height: 14)
            y += h + 2 + 14
            r.rule.isHidden = i == rows.count - 1
            if i < rows.count - 1 {
                r.rule.frame = CGRect(x: 0, y: y + 8, width: bounds.width, height: 1)
                y += 8 + 1 + 10
            }
        }
    }

    public override func updateLayer() {
        for r in rows {
            r.title.color = Themed.color(\.contrastPopoverForeground)
            r.detail.color = Themed.color(\.contrastMutedForeground, 0.75)
            r.rule.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self)
        }
    }
}
