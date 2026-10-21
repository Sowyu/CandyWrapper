import AppKit
import DesignSystem

/// One `ComposerBannerStackItem` (chat/ComposerBannerStack.tsx:12-24): a banner view, its priority,
/// how tall it is when attached, and what dismissing it does.
@MainActor
public struct ComposerBannerStackItem {
    public enum Priority: Sendable { case urgent, activity, notice }
    public let id: String
    public let view: ComposerBannerView
    public var priority: Priority?
    /// The attached height at a width, the 17pt overlap included. Floating drops the overlap.
    public let height: (CGFloat) -> CGFloat
    /// nil: the banner has no X. Called 220 ms after the X, once the banner has left.
    public var onDismiss: (() -> Void)?

    public init(id: String, view: ComposerBannerView, priority: Priority? = nil, height: @escaping (CGFloat) -> CGFloat,
                onDismiss: (() -> Void)? = nil) {
        self.id = id; self.view = view; self.priority = priority; self.height = height; self.onDismiss = onDismiss
    }

    /// `bannerPriority` (ComposerBannerStack.tsx:33-41): urgent, error and warning notices come first,
    /// so they never hide behind an activity banner, then activity, then the rest.
    var rank: Int {
        if priority == .urgent || view.variant != .neutral { return 0 }
        if priority == .activity { return 1 }
        return 2
    }

    /// `items.toSorted(...)`: a stable sort by rank.
    public static func ordered(_ items: [ComposerBannerStackItem]) -> [ComposerBannerStackItem] {
        items.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
    }
}

/// T3's curves for the stack: Tailwind 4 `ease-out` and `ease-in`.
@MainActor enum BannerStackMotion {
    static let easeOut = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
    /// `duration-150` on the grid rows, the expanded column and the peek.
    static let expand: CFTimeInterval = 0.15
    /// `DISMISS_TRANSITION_MS` and `duration-220` on a leaving notice.
    static let dismiss: CFTimeInterval = 0.22
}

/// The notices part of `ComposerBannerStack` (ComposerBannerStack.tsx:51-260): everything behind the
/// front item. Collapsed it is the 12pt peek (`min-h-3`) sitting on the column's top edge; hovering
/// or clicking it expands the other notices as floating cards above the column, `space-y-2 pb-2`.
/// The owner lays out the front item and the queue; this view holds the stacked ones.
///
/// Motion: expanding shows the column at once (`visible`), slides it up 4pt and fades it in over
/// 150 ms ease-out while the grid row opens over the same 150 ms, so its top edge rises from the
/// column. Both are one translate on the column inside a fixed clip: the open row shows the column's
/// top `H * e` points, which is what translating by `(H + 4) * (1 - e)` shows too. Collapsing hides the
/// column at once (`invisible` is not transitioned) and fades the peek back in over 150 ms. A dismissed
/// notice slides 112pt (stacked) or 64pt (front) down and fades over 220 ms ease-in, then leaves.
public final class ComposerBannerStackView: DSView {
    public let peek = ComposerBannerPeekView()
    private let clip = DSView()
    private let column = DSView()
    public private(set) var expanded = false
    /// `exitingItemId`: the notice playing its exit.
    public private(set) var exitingId: String?
    /// The exit's pending `onDismiss`. Cancelled when the item leaves first (a thread switch).
    private var pendingDismiss: DispatchWorkItem?
    /// `onDismiss` ran for `exitingId`; an item still listed after that was kept by its producer.
    private var dismissFired = false
    private var items: [ComposerBannerStackItem] = []
    private var stacked: [ComposerBannerStackItem] { Array(items.dropFirst()) }
    /// The stack changed size; the owner lays out again.
    public var onLayoutChange: (() -> Void)?
    private var tracking: NSTrackingArea?

    public static let peekHeight: CGFloat = 12

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clip.clipsToBounds = true
        clip.isHidden = true
        clip.addSubview(column)
        addSubview(clip)
        addSubview(peek)
        peek.action = { [weak self] in self?.setExpanded(true) }
        setAccessibilityElement(false)
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.group)
        column.setAccessibilityLabel("Other notices")
    }

    /// Whether there is anything behind the front item.
    public var hasStack: Bool { items.count > 1 }

    /// The ordered items; the first is the front, attached outside this view. Reparents the stacked
    /// views into the column and makes them floating.
    public func update(_ ordered: [ComposerBannerStackItem]) {
        if let exitingId {
            let listed = ordered.contains(where: { $0.id == exitingId })
            if !listed || dismissFired {
                // Gone: drop its held exit so the view can come back later, and never dismiss what left
                // before the delay ran out. Still listed after `onDismiss`: the producer kept it, so it
                // shows again instead of blocking every later dismiss.
                for item in items + ordered where item.id == exitingId { Self.clearExit(item.view) }
                pendingDismiss?.cancel()
                pendingDismiss = nil
                dismissFired = false
                self.exitingId = nil
            }
        }
        items = ordered
        if ordered.count < 2, expanded { expanded = false }
        for item in stacked {
            if item.view.superview !== column { column.addSubview(item.view) }
            item.view.placement = .floating
            item.view.joinsAbove = false
            item.view.isHidden = false
        }
        for view in column.subviews where !stacked.contains(where: { $0.view === view }) {
            view.removeFromSuperview()
        }
        peek.variant = stacked.first?.view.variant ?? .neutral
        // `showCollapsedStackCap`: no peek while the front item leaves.
        peek.isHidden = !hasStack || ordered.first?.id == exitingId
        isHidden = !hasStack
        needsLayout = true
    }

    /// The stacked notices' height when open: floating cards, `space-y-2`, `pb-2`.
    public func expandedHeight(width: CGFloat) -> CGFloat {
        let cards = stacked.map { $0.height(width) - ComposerBannerView.overlap }
        return cards.isEmpty ? 0 : cards.reduce(0, +) + 8 * CGFloat(cards.count - 1) + 8
    }

    /// This view's height: the peek collapsed, the open column expanded (`min-h-3`).
    public func height(width: CGFloat) -> CGFloat {
        guard hasStack else { return 0 }
        return expanded ? max(Self.peekHeight, expandedHeight(width: width)) : Self.peekHeight
    }

    public func setExpanded(_ open: Bool) {
        guard open != expanded, !open || hasStack else { return }
        expanded = open
        onLayoutChange?()
        superview?.layoutSubtreeIfNeeded()
        let reduce = Motion.reduced
        if open {
            peek.alphaValue = 0
            clip.isHidden = false
            guard !reduce, let layer = column.layer else { return }
            let h = expandedHeight(width: bounds.width)
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = h + 4
            slide.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            for a in [slide, fade] {
                a.duration = BannerStackMotion.expand
                a.timingFunction = BannerStackMotion.easeOut
                layer.add(a, forKey: a.keyPath)
            }
        } else {
            column.layer?.removeAllAnimations()
            clip.isHidden = true
            peek.alphaValue = 1
            guard !reduce, let layer = peek.layer else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = BannerStackMotion.expand
            fade.timingFunction = BannerStackMotion.easeOut
            layer.add(fade, forKey: "opacity")
        }
    }

    /// `requestDismiss`: one exit at a time, and only for notices with an X. The front item slides
    /// 64pt, a stacked one 112pt (`translate-y-16`, `translate-y-28`).
    public func requestDismiss(_ id: String) {
        guard exitingId == nil, let index = items.firstIndex(where: { $0.id == id }),
              let onDismiss = items[index].onDismiss else { return }
        let item = items[index]
        exitingId = id
        item.view.dismissControl?.isEnabled = false
        if index == 0 { peek.isHidden = true }
        if !Motion.reduced, let layer = item.view.layer {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.toValue = index == 0 ? 64 : 112
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            for a in [slide, fade] {
                a.duration = BannerStackMotion.dismiss
                a.timingFunction = BannerStackMotion.easeIn
                a.fillMode = .forwards
                a.isRemovedOnCompletion = false
                layer.add(a, forKey: "exit." + a.keyPath!)
            }
        } else {
            item.view.alphaValue = 0
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.exitingId == id else { return }
            self.pendingDismiss = nil
            self.dismissFired = true
            onDismiss()
            // A producer that drops the item relays out; one that keeps it gets it back on that pass.
            self.onLayoutChange?()
        }
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + BannerStackMotion.dismiss, execute: work)
    }

    /// The front item lost its exit when it stays (a producer kept it) or comes back later.
    static func clearExit(_ view: ComposerBannerView) {
        view.layer?.removeAnimation(forKey: "exit.transform.translation.y")
        view.layer?.removeAnimation(forKey: "exit.opacity")
        view.alphaValue = 1
        view.dismissControl?.isEnabled = true
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // `absolute inset-x-0 bottom-0 mx-auto h-3 w-[96%]`, snapped to device pixels.
        let pw = (w * 0.96 * 2).rounded() / 2
        peek.frame = NSRect(x: ((w - pw) / 2 * 2).rounded() / 2, y: h - Self.peekHeight, width: pw, height: Self.peekHeight)
        let open = expandedHeight(width: w)
        clip.frame = NSRect(x: 0, y: h - open, width: w, height: open)
        column.frame = clip.bounds
        var y: CGFloat = 0
        for item in stacked {
            let ch = item.height(w) - ComposerBannerView.overlap
            item.view.frame = NSRect(x: 0, y: y, width: w, height: ch)
            y += ch + 8
        }
    }

    // MARK: Hover, focus and Escape (ComposerBannerStack.tsx:118-150)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { setExpanded(true) }

    public override func mouseExited(with event: NSEvent) {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: column) { return }
        setExpanded(false)
    }

    public override func cancelOperation(_ sender: Any?) {
        guard expanded else { return super.cancelOperation(sender) }
        setExpanded(false)
        window?.makeFirstResponder(peek)
    }
}

/// `ComposerBanner.Peek` (ComposerBanner.tsx:84-115): the 12pt cap of the first hidden notice, 96%
/// wide, `rounded-t-2xl` (18, clamped to the 12pt height as CSS scales radii), a 1pt border without
/// a bottom edge in the first hidden notice's severity, the composer glass, and `shadow-md`.
public final class ComposerBannerPeekView: ControlView {
    public var variant = ComposerBannerView.Variant.neutral { didSet { if variant != oldValue { needsDisplay = true } } }
    /// `shadow-md` where it shows: the band on the front item under the peek's bottom edge.
    private let shade = CAGradientLayer()
    private let clip = DSView()
    private let blur = BackdropBlurView()
    private let surface = DSView()
    private let ring = CALayer()
    private static let radius: CGFloat = 12

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        layer?.masksToBounds = false
        // `shadow-md` (0 4px 6px -1px and 0 2px 4px -2px, black at 10%) drawn as the 8pt band it
        // leaves under the peek, as measured on T3's rendering: a static gradient, no blur pass.
        shade.colors = [0.10, 0.078, 0.055, 0.039, 0.027, 0.016, 0.008, 0].map { Themed.black($0).cgColor }
        shade.locations = (0..<8).map { NSNumber(value: Double($0) / 7) }
        layer?.addSublayer(shade)
        clip.clipsToBounds = true
        blur.cornerRadius = Self.radius
        clip.addSubview(blur)
        surface.layer?.cornerRadius = Self.radius
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        clip.addSubview(surface)
        addSubview(clip)
        ring.borderWidth = 2
        ring.cornerRadius = Self.radius + 2
        ring.isHidden = true
        layer?.addSublayer(ring)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show other notices")
    }

    public override func updateLayer() {
        let dark = effectiveAppearance.isDark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.layer?.backgroundColor = Themed.color(light: \.card, 0.8, dark: \.surfaceRaised, 0.8).cgColor(in: self)
        switch variant {
        case .neutral: surface.layer?.borderColor = (dark ? Themed.white(0.05) : Themed.black(0.08)).cgColor
        case .warning: surface.layer?.borderColor = Themed.color(\.warning, 0.24).cgColor(in: self)
        case .error: surface.layer?.borderColor = Themed.color(\.destructive, 0.24).cgColor(in: self)
        }
        ring.borderColor = Themed.color(\.ring).cgColor(in: self)
        ring.isHidden = !state.focusVisible
        CATransaction.commit()
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if old.focusVisible != state.focusVisible { needsDisplay = true }
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        clip.frame = bounds
        // Taller than the clip by the radius, so the bottom border and corners fall outside it.
        surface.frame = NSRect(x: 0, y: 0, width: w, height: h + Self.radius)
        blur.frame = surface.frame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shade.frame = CGRect(x: 1, y: h, width: max(0, w - 2), height: 8)
        shade.startPoint = CGPoint(x: 0.5, y: isFlipped ? 0 : 1)
        shade.endPoint = CGPoint(x: 0.5, y: isFlipped ? 1 : 0)
        ring.frame = bounds.insetBy(dx: -2, dy: -2)
        CATransaction.commit()
    }
}
