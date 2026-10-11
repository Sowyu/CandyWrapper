import AppKit

/// T3's hover reveals, `opacity-0 transition-opacity group-hover/<name>:opacity-100`: a fade on
/// `alphaValue` from wherever the view is now, 150 ms on Tailwind's default curve unless T3 sets a
/// `duration-*`. Reduce Motion and views outside a window snap. Nothing runs once the fade ends.
/// See docs/research/hover-reveals-2026-10-11.md for which reveals fade and which flip at once.
@MainActor
public enum HoverReveal {
    /// Fades `views` in or out. With `hides`, a faded-out view also ends `isHidden`, so it takes
    /// no clicks (`pointer-events-none`) and stops drawing; it is unhidden before it fades in.
    public static func fade(_ views: [NSView], visible: Bool, duration: TimeInterval = Motion.Durations.default, hides: Bool = false) {
        let target: CGFloat = visible ? 1 : 0
        let moving = views.filter { $0.alphaValue != target || (hides && $0.isHidden == visible) }
        guard !moving.isEmpty else { return }
        let animate = duration > 0 && !Motion.reduced && !snapping && moving.contains { $0.window != nil }
        if visible, hides { moving.forEach { $0.isHidden = false } }
        guard animate else {
            moving.forEach { $0.alphaValue = target; if hides, !visible { $0.isHidden = true } }
            return
        }
        let hidesAtEnd = hides && !visible
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = Motion.easeInOut
            moving.forEach { $0.animator().alphaValue = target }
        } completionHandler: {
            guard hidesAtEnd else { return }
            // A hover that came back during the fade set the model value to 1 again.
            MainActor.assumeIsolated { moving.forEach { if $0.alphaValue == 0 { $0.isHidden = true } } }
        }
    }

    /// Fades one view's `alphaValue` to `alpha`, for partial reveals such as `opacity-40 hover:opacity-100`.
    public static func fade(_ view: NSView, to alpha: CGFloat, duration: TimeInterval = Motion.Durations.default) {
        guard view.alphaValue != alpha else { return }
        guard duration > 0, !Motion.reduced, !snapping, view.window != nil else { view.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = Motion.easeInOut
            view.animator().alphaValue = alpha
        }
    }

    private static var snapping = false
    /// Runs `body` with every fade snapping, for a recycled row that now shows another item.
    public static func withoutAnimation(_ body: () -> Void) {
        let old = snapping
        snapping = true
        defer { snapping = old }
        body()
    }

    /// Sets the resting value with no fade, for a recycled row or a new item.
    public static func snap(_ views: [NSView], visible: Bool, hides: Bool = false) {
        for v in views {
            v.layer?.removeAnimation(forKey: "opacity")
            v.alphaValue = visible ? 1 : 0
            if hides { v.isHidden = !visible }
        }
    }
}

/// A view that reveals controls while one of its descendants has keyboard focus, as T3's
/// `group-focus-within/<name>` does. `ControlView` tells its ancestors when `focusVisible` flips.
// ponytail: keyboard focus only; Chromium also pins a reveal after a click focuses a button and
// clears it on the next click anywhere, which AppKit has no event for. Track clicks if users miss it.
@MainActor
public protocol FocusWithinObserver: NSView {
    func focusWithinChanged(_ focused: Bool)
}

/// Hover for a plain view that has no tracking of its own, as a `group` ancestor in T3. The host keeps
/// the group alive: a tracking area does not retain its owner.
@MainActor
public final class HoverGroup: NSResponder {
    public private(set) var hovered = false
    private let onChange: @MainActor (Bool) -> Void

    public init(_ host: NSView, onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        host.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func mouseEntered(with event: NSEvent) { hovered = true; onChange(true) }
    public override func mouseExited(with event: NSEvent) { hovered = false; onChange(false) }
}
