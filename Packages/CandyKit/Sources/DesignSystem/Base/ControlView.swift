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
        didSet {
            guard state != oldValue else { return }
            if transitions.isEmpty || window == nil { return stateDidChange(from: oldValue) }
            Motion.transitioning(transitions) { stateDidChange(from: oldValue) }
        }
    }

    /// The control's `transition-*` class: what fades when hover, press, focus or open state restyles it.
    /// Empty snaps, which is right for T3's buttons and rows (button.tsx:11 animates only shadow and scale).
    public var transitions: Motion.Transition = []

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

    /// Menu and select triggers open on press (base-ui `useClick` with `event: 'mousedown'`,
    /// MenuTrigger.js:157, SelectRoot.js:294). Dragging onto an item and releasing chooses it.
    /// `MenuPopupView.show(from:)` and SelectView turn it on; popover triggers keep opening on release.
    public var opensPopupOnPress = false
    /// Set while a press opened this control's menu, until the button comes up.
    private var pressOpenedAt: TimeInterval?
    /// Set by PopupHost when a press on this trigger closed its popup.
    var pressClosedPopup = false

    open override func mouseDown(with event: NSEvent) {
        guard state.enabled else { return }
        pressClosedPopup = false
        state.active = true
        state.focusVisible = false
        if opensPopupOnPress {
            pressOpenedAt = event.timestamp
            performAction()
            if pressedMenu == nil { pressOpenedAt = nil }
        }
    }

    open override func mouseDragged(with event: NSEvent) {
        guard state.enabled else { return }
        if pressOpenedAt != nil {
            pressedMenu?.mouseMoved(with: event)
            return
        }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        state.active = inside
        state.hovered = inside
    }

    open override func mouseUp(with event: NSEvent) {
        guard state.enabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        state.active = false
        // The press closed this control's open popup (PopupHost swallowed it); the release must not reopen it.
        if pressClosedPopup { pressClosedPopup = false; return }
        if let openedAt = pressOpenedAt {
            pressOpenedAt = nil
            releasePressedMenu(event, heldFor: event.timestamp - openedAt)
            return
        }
        if inside { performAction() }
    }

    /// The menu this control opened, while it is open.
    private var pressedMenu: PressDragMenu? {
        guard let host = window?.contentView?.subviews.lazy.compactMap({ $0 as? PopupHost }).first,
              let content = host.popups.last(where: { $0.trigger === self })?.content else { return nil }
        return pressDragMenu(in: content)
    }

    /// How long the button must be held before a release on `row` chooses it. base-ui ignores a quick
    /// press-and-release that lands on an item (MenuTrigger.js:185-188, 200 ms).
    open func dragSelectDelay(row: Int, in menu: PressDragMenu) -> TimeInterval { 0.2 }

    /// The button came up after a press that opened the menu: choose the item under the pointer, keep the
    /// menu open over the trigger or the popup, or close it anywhere else (MenuTrigger.js:102-123,
    /// SelectTrigger.js:192-206, 2 px slack around the trigger).
    private func releasePressedMenu(_ event: NSEvent, heldFor held: TimeInterval) {
        guard let host = window?.contentView?.subviews.lazy.compactMap({ $0 as? PopupHost }).first,
              let popup = host.popups.last(where: { $0.trigger === self }) else { return }
        if popup.container.bounds.contains(popup.container.convert(event.locationInWindow, from: nil)) {
            if let menu = pressDragMenu(in: popup.content), let row = menu.pressDragRow(at: event.locationInWindow),
               held >= dragSelectDelay(row: row, in: menu) {
                menu.mouseUp(with: event)
            }
            return
        }
        if bounds.insetBy(dx: -2, dy: -2).contains(convert(event.locationInWindow, from: nil)) { return }
        host.close(popup, returnFocus: false)
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

/// Popup content a press on its trigger can drag into and release on: base-ui menus and selects.
/// The trigger forwards drags as mouseMoved (highlight) and the release as mouseUp (choose).
@MainActor
public protocol PressDragMenu: NSView {
    /// The selectable row under a point in window coordinates.
    func pressDragRow(at windowPoint: NSPoint) -> Int?
}

/// The first press-drag menu in `view`'s subtree, itself included.
@MainActor
func pressDragMenu(in view: NSView) -> PressDragMenu? {
    if let menu = view as? PressDragMenu { return menu }
    for sub in view.subviews { if let menu = pressDragMenu(in: sub) { return menu } }
    return nil
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

    /// CSS properties a `transition-*` class animates. `.color` is text and icon color.
    public struct Transition: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let color = Transition(rawValue: 1)
        public static let background = Transition(rawValue: 2)
        public static let border = Transition(rawValue: 4)
        public static let shadow = Transition(rawValue: 8)
        /// Tailwind `transition-colors`: color, background-color, border-color (and fill, stroke).
        public static let colors: Transition = [.color, .background, .border]
    }

    /// What labels, icons and box decorations changed inside `transitioning` animate. Empty otherwise.
    public private(set) static var activeTransitions: Transition = []

    /// Runs `body` so the color changes it makes fade over 150 ms, like a `transition-*` class.
    /// Under Reduce Motion they snap.
    public static func transitioning(_ transitions: Transition, _ body: () -> Void) {
        guard !transitions.isEmpty, !reduced else { return body() }
        let outer = activeTransitions
        activeTransitions = transitions
        defer { activeTransitions = outer }
        body()
    }

    /// Fades a redrawn layer from its old image to its next one, 150 ms. For drawn text and box
    /// decorations a cross-fade of two images in different colors is the same as fading the color.
    public static func crossfade(_ layer: CALayer, duration: CFTimeInterval = Durations.default) {
        guard layer.contents != nil else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = easeInOut
        layer.add(fade, forKey: kCATransition)
    }

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
