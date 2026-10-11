import AppKit
import QuartzCore

/// T3's stacked toast viewport (`toast.tsx:550-690`), top-right: 32px from the right edge,
/// 84px from the top (inset plus the 52px top bar), 360px wide. Add it over the window content with
/// `frame(in:)`; it passes clicks through except on toasts.
/// Hovering the stack expands it and pauses every timer, as does the window losing key status.
/// One one-shot timer waits for the earliest expiry; with no toast nothing is scheduled.
public final class ToastViewport: DSView {
    public static let width: CGFloat = 360
    static let inset: CGFloat = 32

    public static func frame(in bounds: CGRect) -> CGRect {
        let w = min(width, bounds.width - 2 * inset)
        return CGRect(x: bounds.width - inset - w, y: inset + 52, width: w, height: max(0, bounds.height - inset - 52))
    }

    public private(set) var queue = ToastQueue()
    private var views: [Int: ToastView] = [:]
    private var timer: Timer?
    /// Injected for tests.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    public private(set) var isExpanded = false
    private var hovered = false
    private var windowIsKey = true
    private var observers: [NSObjectProtocol] = []

    /// Shows a toast at the front of the stack and returns its id.
    @discardableResult
    public func show(_ toast: ToastView, timeout: TimeInterval = ToastQueue.defaultTimeout) -> Int {
        let id = queue.add(kind: toast.kind, timeout: timeout, now: now())
        toast.id = id
        toast.onDismiss = { [weak self] in self?.dismiss(id) }
        toast.onSwipe = { [weak self] delta, ended in self?.swipe(id, delta: delta, ended: ended) }
        views[id] = toast
        addSubview(toast)
        toast.frame = CGRect(x: 0, y: 0, width: bounds.width, height: toast.height(forWidth: bounds.width))
        relayout(entering: id)
        reschedule()
        return id
    }

    /// Changes a shown toast's text in place; false when it already left.
    @discardableResult
    public func update(_ id: Int, title: String, message: String?) -> Bool {
        guard let view = views[id] else { return false }
        view.setText(title: title, message: message)
        relayout(animated: false)
        return true
    }

    public func dismiss(_ id: Int, swipe: CGPoint? = nil) {
        guard let view = views.removeValue(forKey: id) else { return }
        view.onDidDismiss?()
        let slotY = view.layer?.sublayerTransform.m42 ?? 0
        queue.remove(id, now: now())
        animateOut(view, fromY: slotY, swipe: swipe)
        relayout()
        reschedule()
    }

    // MARK: Layout

    /// Toasts in front-to-back order.
    var orderedViews: [ToastView] { queue.items.compactMap { views[$0.id] } }

    public override func layout() {
        super.layout()
        layer?.masksToBounds = false
        relayout(animated: false)
    }

    private func relayout(entering: Int? = nil, animated: Bool = true) {
        let toasts = orderedViews
        let heights = toasts.map { $0.height(forWidth: bounds.width) }
        let slots = ToastQueue.layout(heights: heights, expanded: isExpanded, limit: queue.limit)
        for (view, slot) in zip(toasts, slots) {
            view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: slot.height)
            view.contentHidden = slot.contentHidden
            let target = Self.transform(slot, width: bounds.width)
            let opacity: Float = slot.limited ? 0 : 1
            if view.id == entering, animated, !Motion.reduced {
                // Top-right enter: from translateX(100% + inset) at the slot's y, opacity 0.
                let from = CATransform3DMakeTranslation(bounds.width + Self.inset, slot.translateY, 0)
                animate(view, transform: (from, target), opacity: (0, opacity))
            } else if animated, !Motion.reduced {
                animate(view, transform: (view.layer?.presentation()?.sublayerTransform ?? target, target),
                        opacity: (view.layer?.presentation()?.opacity ?? opacity, opacity))
            }
            view.layer?.sublayerTransform = target
            view.alphaValue = CGFloat(opacity)
        }
    }

    /// `translateY(y) scale(s)` about the top center (`origin-top`). Applied as the toast's `sublayerTransform`,
    /// because AppKit resets a view layer's `transform` when it syncs geometry; `ToastView.hitTest` maps through it.
    /// Stacking order is subview order: the newest (front) toast is added last.
    static func transform(_ slot: ToastQueue.Slot, width: CGFloat) -> CATransform3D {
        var t = CATransform3DMakeTranslation(width / 2, slot.translateY, 0)
        t = CATransform3DScale(t, slot.scale, slot.scale, 1)
        return CATransform3DTranslate(t, -width / 2, 0, 0)
    }

    /// `transform .5s cubic-bezier(.22,1,.36,1), opacity .5s` (opacity on the default `ease`).
    private func animate(_ view: NSView, transform: (CATransform3D, CATransform3D), opacity: (Float, Float),
                         completion: (@MainActor () -> Void)? = nil) {
        guard let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        let t = CABasicAnimation(keyPath: "sublayerTransform")
        t.fromValue = transform.0
        t.toValue = transform.1
        t.duration = 0.5
        t.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = opacity.0
        o.toValue = opacity.1
        o.duration = 0.5
        o.timingFunction = CAMediaTimingFunction(name: .default)
        layer.add(t, forKey: "sublayerTransform")
        layer.add(o, forKey: "opacity")
        CATransaction.commit()
    }

    /// Exit: fade, and slide out right by 100% + inset, or on in the swipe's direction.
    private func animateOut(_ view: ToastView, fromY: CGFloat, swipe: CGPoint?) {
        let w = bounds.width + Self.inset
        let end: CATransform3D
        if let swipe, abs(swipe.y) > abs(swipe.x) {
            end = CATransform3DMakeTranslation(0, fromY + swipe.y - view.bounds.height - Self.inset, 0)
        } else {
            end = CATransform3DMakeTranslation((swipe?.x ?? 0) + w, fromY, 0)
        }
        guard !Motion.reduced else { view.removeFromSuperview(); return }
        let start = view.layer?.presentation()?.sublayerTransform ?? view.layer?.sublayerTransform ?? CATransform3DIdentity
        view.layer?.sublayerTransform = end
        view.alphaValue = 0
        animate(view, transform: (start, end), opacity: (view.layer?.presentation()?.opacity ?? 1, 0)) { view.removeFromSuperview() }
    }

    // MARK: Swipe

    /// Swipe directions for top-right: right and up. 40px dismisses; less springs back.
    private func swipe(_ id: Int, delta: CGPoint, ended: Bool) {
        guard let view = views[id] else { return }
        let dx = max(0, delta.x), dy = min(0, delta.y)
        let base = Self.transform(currentSlot(id) ?? .init(index: 0, translateY: 0, scale: 1, height: 0, contentHidden: false, limited: false),
                                  width: bounds.width)
        if !ended {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.sublayerTransform = CATransform3DConcat(base, CATransform3DMakeTranslation(dx, dy, 0))
            CATransaction.commit()
        } else if dx >= 40 || dy <= -40 {
            dismiss(id, swipe: CGPoint(x: dx, y: dy))
        } else {
            relayout()
        }
    }

    private func currentSlot(_ id: Int) -> ToastQueue.Slot? {
        let toasts = orderedViews
        let slots = ToastQueue.layout(heights: toasts.map { $0.height(forWidth: bounds.width) }, expanded: isExpanded, limit: queue.limit)
        return zip(toasts, slots).first { $0.0.id == id }?.1
    }

    // MARK: Hover, focus and timers

    func setHovered(_ value: Bool) {
        hovered = value
        updatePause()
    }

    private func updatePause() {
        let expanded = hovered
        let paused = expanded || !windowIsKey
        if expanded != isExpanded { isExpanded = expanded; relayout() }
        if paused != queue.isPaused { queue.setPaused(paused, now: now()) }
        reschedule()
    }

    /// One one-shot timer at the earliest deadline; none while paused or empty.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard let deadline = queue.nextDeadline() else { return }
        let t = Timer(timeInterval: max(0, deadline - now()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var hasScheduledTimer: Bool { timer != nil }

    func fire() {
        for id in queue.expire(now: now()) {
            guard let view = views.removeValue(forKey: id) else { continue }
            animateOut(view, fromY: view.layer?.sublayerTransform.m42 ?? 0, swipe: nil)
        }
        relayout()
        reschedule()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Hover counts only over the stack (toasts plus the 13px gap bridges), not the empty viewport.
    public override func mouseMoved(with event: NSEvent) {
        setHovered(stackRect.contains(convert(event.locationInWindow, from: nil)))
    }

    public override func mouseExited(with event: NSEvent) { setHovered(false) }

    private var stackRect: CGRect {
        let toasts = orderedViews
        guard !toasts.isEmpty else { return .zero }
        let slots = ToastQueue.layout(heights: toasts.map { $0.height(forWidth: bounds.width) }, expanded: isExpanded, limit: queue.limit)
        let bottom = slots.filter { !$0.limited }.map { $0.translateY + $0.height * $0.scale }.max() ?? 0
        return CGRect(x: 0, y: 0, width: bounds.width, height: bottom + 13)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        windowIsKey = window.isKeyWindow
        for (name, key) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowIsKey = key; self?.updatePause() }
            })
        }
        updatePause()
    }
}
