import AppKit
import QuartzCore

/// Interaction base for clickable controls: hover, press, keyboard focus (`:focus-visible`),
/// disabled and the `data-pressed` state T3 sets while a control's menu or popover is open.
/// Subclasses read `state` in `updateLayer()` and restyle; nothing else redraws.
open class ControlView: DSView {
    public struct State: Equatable, Sendable {
        public var hovered = false
        public var active = false        // mouse held down inside (`:active`)
        public var popupOpen = false     // `[data-pressed]` / `data-popup-open`
        public var focusVisible = false  // keyboard focus only, like `:focus-visible`
        public var enabled = true

        /// T3 styles `:hover` and `[data-pressed]` with one rule.
        public var hoverOrPressed: Bool { hovered || popupOpen }
        /// T3 styles `:active` and `[data-pressed]` with one rule.
        public var activeOrPressed: Bool { active || popupOpen }
    }

    public internal(set) var state = State() {
        didSet { if state != oldValue { stateDidChange(from: oldValue) } }
    }

    public var isEnabled: Bool {
        get { state.enabled }
        set { state.enabled = newValue }
    }

    /// Mirrors `data-pressed`: set while this control's menu or popover is open.
    public var isPopupOpen: Bool {
        get { state.popupOpen }
        set { state.popupOpen = newValue }
    }

    // final: a non-final @MainActor closure property hits a Swift 6.4 vtable symbol bug (getter never emitted).
    public final var action: (@MainActor () -> Void)?

    /// Forces a state for the gallery and visual tests.
    public func previewState(_ state: State) { self.state = state }

    /// T3 buttons shrink to 0.97 while held, except triggers with `aria-haspopup`.
    public var scalesWhenPressed = true
    /// `disabled:opacity-64`.
    public var disabledOpacity: Float = 0.64

    private var trackingArea: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
    }

    /// Called after any state change. Default: restyle layers.
    open func stateDidChange(from old: State) {
        needsDisplay = true
        if old.enabled != state.enabled {
            alphaValue = CGFloat(state.enabled ? 1 : disabledOpacity)
            window?.invalidateCursorRects(for: self)
        }
        if old.active != state.active, scalesWhenPressed { animatePressScale(state.active) }
        if old.focusVisible != state.focusVisible {
            var ancestor = superview
            while let view = ancestor {
                (view as? FocusWithinObserver)?.focusWithinChanged(state.focusVisible)
                ancestor = view.superview
            }
        }
    }

    // MARK: Hover

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // Chromium shows :hover in inactive windows too, so track always.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    open override func mouseEntered(with event: NSEvent) { if state.enabled { state.hovered = true } }
    open override func mouseExited(with event: NSEvent) { state.hovered = false }

    open override func resetCursorRects() {
        if state.enabled { addCursorRect(bounds, cursor: .pointingHand) } // `cursor-pointer`
    }

    // MARK: Press

    open override func mouseDown(with event: NSEvent) {
        guard state.enabled else { return }
        state.active = true
        state.focusVisible = false
    }

    open override func mouseDragged(with event: NSEvent) {
        guard state.enabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        state.active = inside
        state.hovered = inside
    }

    open override func mouseUp(with event: NSEvent) {
        guard state.enabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        state.active = false
        if inside { performAction() }
    }

    open func performAction() { action?() }

    /// Controls in the window's top bar take their clicks instead of dragging the window.
    open override var mouseDownCanMoveWindow: Bool { false }

    open override func accessibilityPerformPress() -> Bool {
        guard state.enabled else { return false }
        performAction()
        return true
    }

    // MARK: Keyboard focus

    open override var acceptsFirstResponder: Bool { state.enabled }
    open override var canBecomeKeyView: Bool { state.enabled }
    open override var focusRingType: NSFocusRingType { get { .none } set {} }

    open override func becomeFirstResponder() -> Bool {
        // `:focus-visible`: show the ring only when focus arrived by keyboard.
        state.focusVisible = NSApp.currentEvent?.type == .keyDown
        return true
    }

    open override func resignFirstResponder() -> Bool {
        state.focusVisible = false
        return true
    }

    open override func keyDown(with event: NSEvent) {
        if state.enabled, event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            performAction()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Motion

    /// `transition-[box-shadow,scale]` 150ms `cubic-bezier(.4,0,.2,1)`, scale .97 while active.
    private func animatePressScale(_ pressed: Bool) {
        guard let layer else { return }
        // Scale around the center: the layer's anchor stays at its origin under AppKit.
        // sublayerTransform, because AppKit resets `transform` whenever it syncs the view's geometry
        // (attaching to a window, frame changes). Controls draw only in sublayers and subviews.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(center.x, center.y, 0)
        t = CATransform3DScale(t, pressed ? 0.97 : 1, pressed ? 0.97 : 1, 1)
        t = CATransform3DTranslate(t, -center.x, -center.y, 0)
        if Motion.reduced {
            layer.sublayerTransform = t
            return
        }
        Motion.animate(layer, keyPath: "sublayerTransform", to: NSValue(caTransform3D: t), duration: Motion.Durations.default)
        layer.sublayerTransform = t
    }
}

/// Shared motion values and the Reduce Motion switch.
@MainActor
public enum Motion {
    public enum Durations {
        /// Tailwind's default transition duration.
        public static let `default`: CFTimeInterval = 0.15
    }

    /// Tailwind's default curve, `cubic-bezier(.4, 0, .2, 1)`.
    public static let easeInOut = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)

    public static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    public static func animate(_ layer: CALayer, keyPath: String, to value: Any, duration: CFTimeInterval,
                               timing: CAMediaTimingFunction = easeInOut) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: keyPath)
    }
}
