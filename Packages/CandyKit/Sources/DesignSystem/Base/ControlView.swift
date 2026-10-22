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
            Motion.transitioning(transitions) {
                stateDidChange(from: oldValue)
                // A restyle in `updateLayer` runs now, inside the transition, not at the next display pass.
                if needsDisplay { displayIfNeeded() }
            }
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
        setAccessibilityElement(true)
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
        if old.popupOpen != state.popupOpen { setAccessibilityExpanded(state.popupOpen) } // `aria-expanded`
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
    /// Set it where a menu trigger is built (`menuTrigger()`), so the first press opens too.
    /// Popover triggers keep opening on release.
    public var opensPopupOnPress = false {
        didSet {
            guard opensPopupOnPress else { return }
            scalesWhenPressed = false // `aria-haspopup` triggers do not shrink (button.tsx:11)
            // and are menu buttons, unless a subclass picked a role (a select's pop-up button).
            if accessibilityRole() == .button { setAccessibilityRole(.menuButton) }
        }
    }

    /// Sets `transitions` where the control is declared: `ButtonView(...).transitioning(.colors)`.
    @discardableResult
    public func transitioning(_ transitions: Motion.Transition) -> Self {
        self.transitions = transitions
        return self
    }

    /// Marks this control as a menu or select trigger: it opens on press and does not shrink.
    @discardableResult
    public func menuTrigger() -> Self {
        opensPopupOnPress = true
        return self
    }
    /// Set while a press opened this control's menu, until the button comes up.
    private var pressOpenedAt: TimeInterval?
    /// Set when the press already ran the action, so the release does not run it again.
    private var pressPerformed = false
    /// Set by PopupHost when a press on this trigger closed its popup.
    var pressClosedPopup = false

    open override func mouseDown(with event: NSEvent) {
        guard state.enabled else { return }
        pressClosedPopup = false
        state.active = true
        state.focusVisible = false
        pressPerformed = opensPopupOnPress
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
        guard state.enabled else {
            // The press's own action disabled the control (a menu that loads first): drop the press,
            // or it keeps its pressed style until the next one.
            state.active = false
            pressOpenedAt = nil
            pressPerformed = false
            pressClosedPopup = false
            return
        }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        state.active = false
        // The press closed this control's open popup (PopupHost swallowed it); the release must not reopen it.
        if pressClosedPopup { pressClosedPopup = false; pressPerformed = false; return }
        if let openedAt = pressOpenedAt {
            pressOpenedAt = nil
            pressPerformed = false
            releasePressedMenu(event, heldFor: event.timestamp - openedAt)
            return
        }
        // A menu that opens later (it loads first) or not at all: the press was the click.
        if pressPerformed { pressPerformed = false; return }
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

    // MARK: Accessibility
    // T3 exposes every control through ARIA. Each value is computed when an assistive app asks, so
    // nothing runs while nobody asks.

    open override func accessibilityPerformPress() -> Bool {
        guard state.enabled else { return false }
        performAction()
        return true
    }

    /// What VoiceOver calls a control with no explicit label: the text it draws.
    open var accessibilityText: String? { Self.drawnText(in: self) }

    /// The visible text, like a native button's title. Explicit titles win; an explicit label replaces the
    /// drawn text, as `aria-label` replaces a button's content in its accessible name.
    open override func accessibilityTitle() -> String? {
        if let explicit = super.accessibilityTitle(), !explicit.isEmpty { return explicit }
        if let label = super.accessibilityLabel(), !label.isEmpty { return nil }
        return accessibilityText
    }

    /// `aria-label`, else the tooltip when the control shows no text (an icon button).
    open override func accessibilityLabel() -> String? {
        if let explicit = super.accessibilityLabel(), !explicit.isEmpty { return explicit }
        guard accessibilityTitle()?.isEmpty ?? true else { return nil }
        return TooltipController.text(for: self) ?? toolTip
    }

    open override func isAccessibilityEnabled() -> Bool { state.enabled }

    /// A select's value is the option it shows, which an explicit label would otherwise hide. Toggles that were
    /// never switched on have set no value yet: they read as off (`aria-checked="false"`, `aria-pressed="false"`).
    open override func accessibilityValue() -> Any? {
        if let explicit = super.accessibilityValue() { return explicit }
        switch accessibilityRole() {
        case .popUpButton?: return accessibilityText
        case .checkBox?, .radioButton?: return 0
        default: return nil
        }
    }

    /// VoiceOver's "show menu" opens the context menu a right click opens, on controls that have one.
    open override func accessibilityPerformShowMenu() -> Bool {
        let nsViewImp = class_getMethodImplementation(NSView.self, #selector(rightMouseDown(with:)))
        guard let window, class_getMethodImplementation(type(of: self), #selector(rightMouseDown(with:))) != nsViewImp,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return false }
        rightMouseDown(with: event)
        return true
    }

    private static let namedByContentRoles: Set<NSAccessibility.Role> = [.button, .menuButton, .popUpButton, .checkBox, .radioButton, .menuItem, .link, .staticText]

    /// True inside a control that VoiceOver reads as one element: its labels are its name, not separate text.
    public static func isInsideControlElement(_ view: NSView) -> Bool {
        var ancestor = view.superview
        while let v = ancestor {
            if v.isAccessibilityElement(), let role = v.accessibilityRole(), namedByContentRoles.contains(role) { return true }
            ancestor = v.superview
        }
        return false
    }

    /// The text of the labels this control draws, skipping nested controls and hidden views.
    public static func drawnText(in view: NSView) -> String? {
        var parts: [String] = []
        func collect(_ v: NSView) {
            for sub in v.subviews where !sub.isHidden && sub.alphaValue > 0 && !(sub is ControlView) {
                if let label = sub as? LabelView {
                    if !label.text.isEmpty { parts.append(label.text + (label.emphasizedSuffix ?? "")) }
                } else if let block = sub as? TextBlockView {
                    if !block.text.isEmpty { parts.append(block.text) }
                } else {
                    collect(sub)
                }
            }
        }
        collect(view)
        let text = parts.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    // MARK: Keyboard focus

    open override var acceptsFirstResponder: Bool { state.enabled }
    open override var canBecomeKeyView: Bool { state.enabled }
    open override var focusRingType: NSFocusRingType { get { .none } set {} }

    open override func becomeFirstResponder() -> Bool {
        // `:focus-visible`: show the ring only when focus arrived by keyboard.
        state.focusVisible = NSApp.currentEvent?.type == .keyDown
        if state.focusVisible { scrollIntoView() }
        return true
    }

    /// The browser scrolls a control that takes keyboard focus into view, through every scrolling ancestor.
    private func scrollIntoView() {
        var view: NSView = self, rect = bounds
        while let scroll = view.enclosingScrollView {
            view.scrollToVisible(rect)
            rect = scroll.convert(rect, from: view).intersection(scroll.bounds)
            guard !rect.isEmpty else { return }
            view = scroll
        }
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

public extension NSView {
    /// Marks the view for display and, in a window, displays it now inside `Motion.transitioning`, so an
    /// `updateLayer` restyle fades like a `transition-*` class. For views that track hover themselves.
    func redisplay(transitioning transitions: Motion.Transition) {
        needsDisplay = true
        guard window != nil else { return }
        Motion.transitioning(transitions) { displayIfNeeded() }
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

    public static var reduced: Bool { reducedOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Replaces the system's Reduce Motion setting while set. Tests set it from a synchronous main
    /// actor body and clear it before returning, so a Mac with Reduce Motion on still runs them.
    nonisolated(unsafe) public static var reducedOverride: Bool?

    /// Endless decorative loops (spinners, shimmers, pings, skeletons) draw at most 30 frames a second.
    /// Without a range Core Animation runs them at the display's rate, 120 Hz on ProMotion, and keeps
    /// the window server compositing at that rate for as long as an agent works. macOS's own spinners
    /// step at about this rate.
    public static let loopFrameRate = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)

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
    /// How long those changes take: 150 ms unless a `duration-*` class says otherwise.
    public private(set) static var activeDuration: CFTimeInterval = Durations.default

    /// Runs `body` so the color changes it makes fade over 150 ms (or `duration`), like a `transition-*`
    /// class. Under Reduce Motion they snap.
    public static func transitioning(_ transitions: Transition, duration: CFTimeInterval = Durations.default, _ body: () -> Void) {
        guard !transitions.isEmpty, !reduced else { return body() }
        let outer = (activeTransitions, activeDuration)
        activeTransitions = transitions
        activeDuration = duration
        defer { (activeTransitions, activeDuration) = outer }
        body()
    }

    /// Fades a redrawn layer from its old image to its next one, 150 ms (or the active `duration-*`). For
    /// drawn text and box decorations a cross-fade of two images in different colors is the same as fading the color.
    public static func crossfade(_ layer: CALayer, duration: CFTimeInterval = Motion.activeDuration) {
        guard layer.contents != nil else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = easeInOut
        layer.add(fade, forKey: kCATransition)
    }

    /// Sets a layer's background color. Inside `transitioning` with `.background` it fades from what is on
    /// screen, as `transition-colors` fades `background-color`; otherwise it snaps.
    public static func setBackground(_ layer: CALayer?, _ color: CGColor?) {
        setColor(layer, \.backgroundColor, "backgroundColor", color, fadesWith: .background)
    }

    /// Sets a layer's border color; fades inside `transitioning` with `.border`.
    public static func setBorderColor(_ layer: CALayer?, _ color: CGColor?) {
        setColor(layer, \.borderColor, "borderColor", color, fadesWith: .border)
    }

    private static func setColor(_ layer: CALayer?, _ property: ReferenceWritableKeyPath<CALayer, CGColor?>, _ key: String,
                                 _ color: CGColor?, fadesWith kind: Transition) {
        guard let layer else { return }
        let old = (layer.presentation() ?? layer)[keyPath: property]
        // Set first: on a plain sublayer the set adds an implicit animation under the same key, which the fade replaces.
        layer[keyPath: property] = color
        if activeTransitions.contains(kind), !CFEqual(old ?? CGColor.clear, color ?? CGColor.clear) {
            let fade = CABasicAnimation(keyPath: key)
            fade.fromValue = old ?? CGColor.clear
            fade.toValue = color ?? CGColor.clear
            fade.duration = activeDuration
            fade.timingFunction = easeInOut
            layer.add(fade, forKey: key)
        }
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
