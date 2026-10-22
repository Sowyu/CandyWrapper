import AppKit

/// T3's `TooltipPopup` (`tooltip.tsx`). Desktop values. Spec: docs/research/recovered/ui-components-a.md 15.
public final class TooltipView: DSView, PopupContent {
    public enum Variant: Sendable { case `default`, glass, code }

    public let variant: Variant
    private let decoration = BoxDecorationLayer()
    private let dropShadow = PopupShadowLayer()
    private let label = LabelView()
    public var frostRadius: CGFloat { 8 }

    public init(_ text: String, variant: Variant = .default) {
        self.variant = variant
        super.init(frame: .zero)
        decoration.host = self
        dropShadow.host = self
        layer?.addSublayer(dropShadow)
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        let look = (variant == .glass ? PopupSurface.tooltipGlass : .tooltip).split(radius: 8)
        decoration.boxStyle = look.box
        dropShadow.radius = 8
        dropShadow.shadows = look.shadows
        label.text = text
        label.color = PopupSurface.text
        if variant == .code {
            label.font = DSFont.mono(11)
            label.lineHeight = 17.875 // leading-relaxed
        } else {
            label.font = DSFont.ui(12)
            label.lineHeight = 16.5   // leading-snug beats text-xs
        }
        addSubview(label)
    }

    public var text: String {
        get { label.text }
        set { label.text = newValue; wrapped?.text = newValue; invalidateIntrinsicContentSize(); needsLayout = true }
    }

    /// Text past `max-w-80` (`max-w-120` for code) wraps, balanced (`text-balance wrap-anywhere`). One-line
    /// tooltips keep the label; the block exists only once a long text needs it.
    private var maxText: CGFloat { (variant == .code ? 480 : 320) - 18 }
    private var wrapped: TextBlockView?
    /// A "\n" is a hard break, like the stacked `<div>`s of a two-line tooltip.
    private var wraps: Bool { label.textWidth > maxText || label.text.contains("\n") }
    private func wrappedBlock() -> TextBlockView {
        if let wrapped { return wrapped }
        let block = TextBlockView(label.text, font: label.font, lineHeight: label.lineHeight, color: label.color)
        block.balanced = variant != .code
        addSubview(block)
        wrapped = block
        return block
    }

    public override var intrinsicContentSize: NSSize {
        guard wraps else { return NSSize(width: label.textWidth + 18, height: (label.lineHeight ?? 16.5) + 10) }
        // A shrink-to-fit box whose text overflows takes the whole max width; balancing only evens the lines.
        // Hard-broken lines that all fit take the widest line instead.
        let block = wrappedBlock()
        var width = maxText
        if label.text.contains("\n") {
            let layout = block.layout(forWidth: maxText)
            if layout.lines.count == label.text.split(separator: "\n", omittingEmptySubsequences: false).count {
                width = min(maxText, ceil(layout.widths.max() ?? 0))
            }
        }
        return NSSize(width: width + 18, height: block.height(forWidth: maxText) + 10)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        dropShadow.update(boxSize: bounds.size)
        let frame = NSRect(x: 9, y: 5, width: bounds.width - 18, height: bounds.height - 10)
        label.isHidden = wraps
        wrapped?.isHidden = !wraps
        if wraps { wrappedBlock().frame = frame } else { label.frame = frame }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        dropShadow.update(boxSize: bounds.size)
    }
}

/// Shows a tooltip while the pointer rests on a view, with base-ui's delays: open after `delay`
/// (600ms default), close after `closeDelay` (0), and open at once with no motion when another
/// tooltip closed less than the provider `timeout` (400ms) ago.
@MainActor
public final class TooltipController: NSResponder, HoverSyncClient {
    public var text: String
    public var variant: TooltipView.Variant
    public var placement: PopupPlacement
    public var delay: TimeInterval
    public var closeDelay: TimeInterval
    /// Built only when shown; custom cards share the tooltip lifetime and placement.
    public var content: (() -> (NSView & PopupContent))?
    public static var providerTimeout: TimeInterval = 0.4

    private weak var view: NSView?
    private var tracking: NSTrackingArea?
    private var pending: DispatchWorkItem?
    private var popup: OpenPopup?
    private static var lastClosed: TimeInterval = 0

    /// Attaches to `view` and stays alive as long as the view does.
    @discardableResult
    public static func attach(to view: NSView, text: String, variant: TooltipView.Variant = .default,
                              placement: PopupPlacement = .tooltip, delay: TimeInterval = 0.6, closeDelay: TimeInterval = 0) -> TooltipController {
        let c = TooltipController(view: view, text: text, variant: variant, placement: placement, delay: delay, closeDelay: closeDelay)
        objc_setAssociatedObject(view, &associationKey, c, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return c
    }

    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    /// The tooltip text attached to `view`, for its accessibility label.
    static func text(for view: NSView) -> String? {
        guard let c = objc_getAssociatedObject(view, &associationKey) as? TooltipController, !c.text.isEmpty else { return nil }
        return c.text
    }

    init(view: NSView, text: String, variant: TooltipView.Variant, placement: PopupPlacement, delay: TimeInterval, closeDelay: TimeInterval) {
        self.view = view; self.text = text; self.variant = variant; self.placement = placement
        self.delay = delay; self.closeDelay = closeDelay
        super.init()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        view.addTrackingArea(area)
        tracking = area
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func mouseEntered(with event: NSEvent) { schedule(open: true) }
    public override func mouseExited(with event: NSEvent) { schedule(open: false) }

    /// One-shot delay, then open or close. The instant path skips both the delay and the motion.
    func schedule(open: Bool) {
        pending?.cancel()
        let instant = open && Date().timeIntervalSinceReferenceDate - Self.lastClosed < Self.providerTimeout
        let wait = open ? (instant ? 0 : delay) : closeDelay
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { open ? self?.show(instant: instant) : self?.hide() } }
        pending = work
        if wait == 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work) }
    }

    public func show(instant: Bool = false) {
        guard popup == nil, (!text.isEmpty || content != nil), let view, !view.isHiddenOrHasHiddenAncestor, let host = view.popupHost else { return }
        // Redesign, after Capy: no tooltip over the trigger's own open menu. Other themes keep T3's, which shows it.
        if ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark),
           host.popups.contains(where: { $0.trigger === view && !$0.isPassive }) { return }
        let tip = content?() ?? TooltipView(text, variant: variant)
        popup = host.open(tip, trigger: view, placement: placement, motion: instant ? .none : .tooltip,
                          pressesTrigger: false, returnsFocus: false, passive: true)
        popup?.onClose = { [weak self] in
            Self.lastClosed = Date().timeIntervalSinceReferenceDate
            self?.popup = nil
        }
    }

    public func hide() {
        pending?.cancel()
        pending = nil
        guard let popup, let host = popup.container.superview as? PopupHost else { return }
        host.close(popup, returnFocus: false)
    }
}
