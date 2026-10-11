import AppKit

/// T3's `TooltipPopup` (`tooltip.tsx`). Desktop values. Spec: docs/research/recovered/ui-components-a.md 15.
public final class TooltipView: DSView, PopupContent {
    public enum Variant: Sendable { case `default`, glass, code }

    public let variant: Variant
    private let decoration = BoxDecorationLayer()
    private let dropShadow = PopupShadowLayer()
    private let label = LabelView()

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
        set { label.text = newValue; invalidateIntrinsicContentSize() }
    }

    // ponytail: one line, truncated at max-w-80 (480 for code); add balanced wrapping when a long tooltip shows up
    public override var intrinsicContentSize: NSSize {
        let maxText: CGFloat = (variant == .code ? 480 : 320) - 18
        return NSSize(width: min(label.textWidth, maxText) + 18, height: (label.lineHeight ?? 16.5) + 10)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        dropShadow.update(boxSize: bounds.size)
        label.frame = NSRect(x: 9, y: 5, width: bounds.width - 18, height: bounds.height - 10)
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
public final class TooltipController: NSResponder {
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
