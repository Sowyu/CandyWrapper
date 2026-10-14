import AppKit
import QuartzCore

// MARK: - Positioning

/// base-ui's positioner options (ui-components-a.md 1.7 and 24.2). LTR only, so `inline-end` is right.
public struct PopupPlacement: Equatable, Sendable {
    public enum Side: Sendable, Equatable { case top, bottom, left, right
        var opposite: Side { switch self { case .top: .bottom; case .bottom: .top; case .left: .right; case .right: .left } }
        var isVertical: Bool { self == .top || self == .bottom }
    }
    public enum Align: Sendable, Equatable { case start, center, end }
    /// base-ui's `collisionAvoidance.fallbackAxisSide`: `Z2` is `.none` (dropdowns), `Q2` is `.end` (popups).
    public enum FallbackAxisSide: Sendable, Equatable { case none, end }

    public var side: Side
    public var align: Align
    public var sideOffset: CGFloat
    public var alignOffset: CGFloat
    public var collisionPadding: CGFloat = 5
    public var fallbackAxisSide: FallbackAxisSide

    public init(side: Side = .bottom, align: Align = .center, sideOffset: CGFloat = 4, alignOffset: CGFloat = 0,
                fallbackAxisSide: FallbackAxisSide = .end) {
        self.side = side; self.align = align; self.sideOffset = sideOffset; self.alignOffset = alignOffset
        self.fallbackAxisSide = fallbackAxisSide
    }

    /// `menu.tsx:23-28`: bottom, center, 4, Z2.
    public static let menu = PopupPlacement(side: .bottom, align: .center, sideOffset: 4, fallbackAxisSide: .none)
    /// `menu.tsx:301-325`: inline-end, start, 0, -5, Q2.
    public static let submenu = PopupPlacement(side: .right, align: .start, sideOffset: 0, alignOffset: -5, fallbackAxisSide: .end)
    /// base-ui context menu: align start, alignOffset 2, sideOffset -5.
    public static let contextMenu = PopupPlacement(side: .bottom, align: .start, sideOffset: -5, alignOffset: 2, fallbackAxisSide: .none)
    /// Select, Combobox and Autocomplete: bottom, start, 4, Z2.
    public static let dropdown = PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none)
    /// `popover.tsx:43-46`: bottom, center, 4, Q2.
    public static let popover = PopupPlacement(side: .bottom, align: .center, sideOffset: 4, fallbackAxisSide: .end)
    /// `tooltip.tsx:85-87`: top, center, 4, Q2.
    public static let tooltip = PopupPlacement(side: .top, align: .center, sideOffset: 4, fallbackAxisSide: .end)
}

/// Floating UI's offset, flip and shift middleware as base-ui configures them, in a top-left space.
public enum PopupPositioner {
    public struct Result: Equatable {
        public var frame: CGRect
        public var side: PopupPlacement.Side
        /// `--transform-origin` in the popup's own coordinates: the point on the trigger edge.
        public var transformOrigin: CGPoint
        /// `--available-width` / `--available-height` on the chosen side.
        public var available: CGSize
    }

    public static func place(size: CGSize, anchor: CGRect, in bounds: CGRect, _ p: PopupPlacement) -> Result {
        // Flip: preferred side, its opposite, then (Q2 only) the perpendicular sides. The flip check uses padding + 1.
        // base-ui's default `collisionAvoidance.align` is "flip" (flip `crossAxis: 'alignment'`, flipAlignment): a
        // start or end popup that overflows across its side tries the other alignment first, so a bottom-end
        // menu near the window's left edge opens bottom-start, as the sidebar's snooze menu does in T3.
        // Centered popups shift before they flip, so only their side flips.
        let flipsAlign = p.align != .center
        func other(_ a: PopupPlacement.Align) -> PopupPlacement.Align { a == .start ? .end : a == .end ? .start : a }
        var candidates: [(side: PopupPlacement.Side, align: PopupPlacement.Align)] = flipsAlign
            ? [(p.side, p.align), (p.side, other(p.align)), (p.side.opposite, p.align), (p.side.opposite, other(p.align))]
            : [(p.side, p.align), (p.side.opposite, p.align)]
        if p.fallbackAxisSide == .end {
            for side in (p.side.isVertical ? [PopupPlacement.Side.right, .left] : [.bottom, .top]) {
                candidates.append((side, p.align))
                if flipsAlign { candidates.append((side, other(p.align))) }
            }
        }
        let flipBounds = bounds.insetBy(dx: p.collisionPadding + 1, dy: p.collisionPadding + 1)
        var chosen = p.side, chosenAlign = p.align
        var fits: (side: PopupPlacement.Side, align: PopupPlacement.Align, cross: CGFloat)?
        var best: (side: PopupPlacement.Side, align: PopupPlacement.Align, overflow: CGFloat)?
        var done = false
        for c in candidates {
            var q = p; q.align = c.align
            let rect = coords(size: size, anchor: anchor, side: c.side, q)
            let o = mainOverflow(rect, side: c.side, flipBounds)
            let cross = c.side.isVertical ? max(flipBounds.minX - rect.minX, rect.maxX - flipBounds.maxX)
                : max(flipBounds.minY - rect.minY, rect.maxY - flipBounds.maxY)
            // Cross-axis overflow counts only between alignments of the preferred axis.
            let checksCross = flipsAlign && c.side.isVertical == p.side.isVertical
            if o <= 0, !checksCross || cross <= 0 { chosen = c.side; chosenAlign = c.align; done = true; break }
            if o <= 0, fits == nil || cross < fits!.cross { fits = (c.side, c.align, cross) }
            // bestFit: fewest overflowing points over both axes.
            let total = overflowSum(rect, flipBounds)
            if best == nil || total < best!.overflow { best = (c.side, c.align, total) }
        }
        if !done, let fits { chosen = fits.side; chosenAlign = fits.align }
        else if !done, let best { chosen = best.side; chosenAlign = best.align }

        var aligned = p
        aligned.align = chosenAlign
        var frame = coords(size: size, anchor: anchor, side: chosen, aligned)
        // Shift along the alignment axis to stay inside the boundary minus collision padding.
        let inner = bounds.insetBy(dx: p.collisionPadding, dy: p.collisionPadding)
        if chosen.isVertical {
            frame.origin.x = clamp(frame.origin.x, inner.minX, inner.maxX - frame.width)
        } else {
            frame.origin.y = clamp(frame.origin.y, inner.minY, inner.maxY - frame.height)
        }
        // ponytail: the popup never leaves the window, it overlaps the trigger instead; base-ui lets it clip.
        frame.origin.x = clamp(frame.origin.x, bounds.minX, bounds.maxX - frame.width)
        frame.origin.y = clamp(frame.origin.y, bounds.minY, bounds.maxY - frame.height)

        let available: CGSize = switch chosen {
        case .bottom: CGSize(width: inner.width, height: inner.maxY - anchor.maxY - p.sideOffset)
        case .top: CGSize(width: inner.width, height: anchor.minY - p.sideOffset - inner.minY)
        case .right: CGSize(width: inner.maxX - anchor.maxX - p.sideOffset, height: inner.height)
        case .left: CGSize(width: anchor.minX - p.sideOffset - inner.minX, height: inner.height)
        }
        let origin: CGPoint = switch chosen {
        case .bottom: CGPoint(x: anchor.midX - frame.minX, y: -p.sideOffset)
        case .top: CGPoint(x: anchor.midX - frame.minX, y: frame.height + p.sideOffset)
        case .right: CGPoint(x: -p.sideOffset, y: anchor.midY - frame.minY)
        case .left: CGPoint(x: frame.width + p.sideOffset, y: anchor.midY - frame.minY)
        }
        return Result(frame: frame, side: chosen, transformOrigin: origin, available: available)
    }

    static func coords(size: CGSize, anchor: CGRect, side: PopupPlacement.Side, _ p: PopupPlacement) -> CGRect {
        var x: CGFloat, y: CGFloat
        switch side {
        case .bottom: y = anchor.maxY + p.sideOffset; x = 0
        case .top: y = anchor.minY - p.sideOffset - size.height; x = 0
        case .right: x = anchor.maxX + p.sideOffset; y = 0
        case .left: x = anchor.minX - p.sideOffset - size.width; y = 0
        }
        if side.isVertical {
            switch p.align {
            case .start: x = anchor.minX + p.alignOffset
            case .center: x = anchor.midX - size.width / 2 + p.alignOffset
            case .end: x = anchor.maxX - size.width - p.alignOffset
            }
        } else {
            switch p.align {
            case .start: y = anchor.minY + p.alignOffset
            case .center: y = anchor.midY - size.height / 2 + p.alignOffset
            case .end: y = anchor.maxY - size.height - p.alignOffset
            }
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func mainOverflow(_ r: CGRect, side: PopupPlacement.Side, _ b: CGRect) -> CGFloat {
        switch side {
        case .bottom: r.maxY - b.maxY
        case .top: b.minY - r.minY
        case .right: r.maxX - b.maxX
        case .left: b.minX - r.minX
        }
    }

    static func overflowSum(_ r: CGRect, _ b: CGRect) -> CGFloat {
        [r.maxY - b.maxY, b.minY - r.minY, r.maxX - b.maxX, b.minX - r.minX].map { max(0, $0) }.reduce(0, +)
    }

    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { hi < lo ? lo : min(max(v, lo), hi) }
}

// MARK: - Popup content

/// Keys the open popup sees. The host maps NSEvents to these so tests can drive popups without an event loop.
public enum PopupKey: Equatable, Sendable {
    case up, down, left, right, home, end, enter, space, escape, tab
    case character(String)

    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 115: self = .home
        case 119: self = .end
        case 36, 76: self = .enter
        case 53: self = .escape
        case 48: self = .tab
        case 49: self = .space
        default:
            guard let c = event.characters, !c.isEmpty,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            self = .character(c)
        }
    }
}

/// A view shown by `PopupHost`. Popups size themselves; the host positions them.
@MainActor
public protocol PopupContent: NSView {
    /// Returns true when the key was used. Escape that nobody handles closes the popup.
    func popupHandleKey(_ key: PopupKey) -> Bool
    /// Natural size, before the host caps it to the available space.
    var popupSize: CGSize { get }
    /// The surface's corner radius, for the blur classic Glass puts under every popup.
    var frostRadius: CGFloat { get }
}

public extension PopupContent {
    func popupHandleKey(_ key: PopupKey) -> Bool { false }
    var popupSize: CGSize { intrinsicContentSize }
    var frostRadius: CGFloat { 10 }
}

/// T3's popup motion: `data-starting-style` / `data-ending-style` scale and opacity, 150ms.
public struct PopupMotion: Sendable, Equatable {
    public var enterScale: CGFloat?
    public var exitScale: CGFloat?
    public var duration: CFTimeInterval = Motion.Durations.default

    public static let none = PopupMotion(enterScale: nil, exitScale: nil)
    /// Popover: scale .98 + opacity 0 both ways. T3 3105 f570294df (ui/popover.tsx:92) added the ending style.
    public static let popover = PopupMotion(enterScale: 0.98, exitScale: 0.98)
    /// Tooltip and PreviewCard: scale .98 + opacity 0 both ways.
    public static let tooltip = PopupMotion(enterScale: 0.98, exitScale: 0.98)
}

/// One open popup.
@MainActor
public final class OpenPopup {
    public let content: PopupContent
    public weak var trigger: NSView?
    public let placement: PopupPlacement
    public let motion: PopupMotion
    /// Anchor in the trigger's coordinates; nil uses its bounds. Context menus pass the click point.
    let anchorRect: CGRect?
    /// Menus and Select: a click outside is swallowed (base-ui's modal backdrop).
    let swallowsOutsideClick: Bool
    /// Sets `isPopupOpen` on a ControlView trigger (`data-pressed`).
    let pressesTrigger: Bool
    /// Moves keyboard focus back to the trigger on close (menus, select, popover).
    let returnsFocus: Bool
    /// Tooltips never take keys and never close other popups.
    var isPassive = false
    /// Combobox: pressing the trigger (its input) leaves the popup open.
    public var keepsOpenOnTriggerPress = false
    /// Child popups (submenus) close with their parent.
    weak var parent: OpenPopup?
    public internal(set) var result: PopupPositioner.Result?
    /// Called once after the popup closes.
    public var onClose: (@MainActor () -> Void)?
    let container = PopupContainer()
    /// Scroll observers that keep the popup on a trigger that scrolls; gone when the popup closes.
    var anchorObservers: [NSObjectProtocol] = []

    init(content: PopupContent, trigger: NSView?, anchorRect: CGRect?, placement: PopupPlacement, motion: PopupMotion,
         swallowsOutsideClick: Bool, pressesTrigger: Bool, returnsFocus: Bool, parent: OpenPopup?) {
        self.content = content; self.trigger = trigger; self.anchorRect = anchorRect; self.placement = placement
        self.motion = motion; self.swallowsOutsideClick = swallowsOutsideClick; self.pressesTrigger = pressesTrigger
        self.returnsFocus = returnsFocus; self.parent = parent
        container.addSubview(content)
    }
}

/// Holds one popup; its layer carries the scale and opacity transitions around the transform origin.
final class PopupContainer: DSView {
    /// Classic Glass's blur under the popup's frosted surface (`WindowGlass.syncPaneBlur`).
    private var paneBlur: BackdropBlurView?
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncBlur()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncBlur()
    }
    private func syncBlur() {
        paneBlur = WindowGlass.syncPaneBlur(paneBlur, in: self, radius: (subviews.last as? PopupContent)?.frostRadius ?? 10)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? super.hitTest(point) : nil
    }
    override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }
}

// MARK: - Host

/// An overlay above a window's content that hosts every open popup, like T3's portal inside the
/// web viewport. No child windows. Transparent to the mouse except over open popups.
@MainActor
public final class PopupHost: DSView {
    public private(set) var popups: [OpenPopup] = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// Closed tooltips still fading out.
    private var exitingPassive: [PopupContainer] = []

    /// The host for `window`, created on first use as the topmost subview of the content view.
    public static func host(for window: NSWindow) -> PopupHost {
        guard let content = window.contentView else { fatalError("PopupHost needs a content view") }
        if let existing = content.subviews.compactMap({ $0 as? PopupHost }).first { return existing }
        let host = PopupHost(frame: content.bounds)
        host.autoresizingMask = [.width, .height]
        content.addSubview(host, positioned: .above, relativeTo: nil)
        return host
    }

    // A transparent NSView says yes by default; over the top bar that let a press that opened a menu
    // drag the window when the pointer moved on to an item.
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        for popup in popups.reversed() {
            if let hit = popup.container.hitTest(convert(point, from: superview)) { return hit }
        }
        return nil
    }

    /// Opens `content` next to `trigger`. Closes any open popup that is not an ancestor first.
    @discardableResult
    public func open(_ content: PopupContent, trigger: NSView?, anchorRect: CGRect? = nil, placement: PopupPlacement,
                     motion: PopupMotion = .none, swallowsOutsideClick: Bool = false, pressesTrigger: Bool = true,
                     returnsFocus: Bool = true, parent: OpenPopup? = nil, passive: Bool = false) -> OpenPopup {
        if let parent { closeChildren(of: parent) } else if passive { popups.filter(\.isPassive).forEach { close($0, returnFocus: false) } } else { closeAll() }
        if passive {
            // One tooltip or hover card at a time: one that is still fading out goes now, as base-ui's
            // provider closes the previous tooltip instantly when the next one opens (`data-instant`).
            for container in exitingPassive { container.layer?.removeAllAnimations(); container.removeFromSuperview() }
            exitingPassive.removeAll()
        }
        // Keep the host above content added after it.
        if let superview, superview.subviews.last !== self { superview.addSubview(self, positioned: .above, relativeTo: nil) }
        let popup = OpenPopup(content: content, trigger: trigger, anchorRect: anchorRect, placement: placement, motion: motion,
                              swallowsOutsideClick: swallowsOutsideClick, pressesTrigger: pressesTrigger,
                              returnsFocus: returnsFocus, parent: parent)
        popup.isPassive = passive
        popups.append(popup)
        addSubview(popup.container)
        reposition(popup)
        followTrigger(popup)
        if pressesTrigger { (trigger as? ControlView)?.isPopupOpen = true }
        if let control = trigger as? ControlView, pressDragMenu(in: content) != nil {
            // Backstop for a trigger built without `menuTrigger()`: it opens on press from its second use.
            control.opensPopupOnPress = true
        }
        animate(popup, entering: true)
        installMonitors()
        return popup
    }

    /// Recomputes the position, for example after the content changed size.
    public func reposition(_ popup: OpenPopup) {
        let anchor: CGRect
        if let trigger = popup.trigger, trigger.window === window {
            anchor = convert(popup.anchorRect ?? trigger.bounds, from: trigger)
        } else {
            anchor = popup.anchorRect ?? .zero
        }
        var size = popup.content.popupSize
        var result = PopupPositioner.place(size: size, anchor: anchor, in: bounds, popup.placement)
        // `max-h-(--available-height)`: the popup never grows past the space on its side.
        let limit = result.side.isVertical ? result.available.height : bounds.height - 2 * popup.placement.collisionPadding
        if size.height > limit, limit > 0 {
            size.height = limit
            result = PopupPositioner.place(size: size, anchor: anchor, in: bounds, popup.placement)
        }
        popup.result = result
        let frame = result.frame
        popup.container.frame = frame
    }

    /// floating-ui's `autoUpdate` keeps an open popup on its trigger when an ancestor scrolls. base-ui's
    /// tooltip positioner glides there (`transition-[top,left,right,bottom,transform]`, tooltip.tsx:105);
    /// a popover's positioner transitions only `transform`, which base-ui does not position with
    /// (popover.tsx:76), so it moves at once, as menus and selects do. Reduce Motion snaps.
    private func followTrigger(_ popup: OpenPopup) {
        var clip = popup.trigger?.enclosingScrollView
        while let scroll = clip {
            let view = scroll.contentView
            view.postsBoundsChangedNotifications = true
            popup.anchorObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view, queue: .main) {
                [weak self, weak popup] _ in
                MainActor.assumeIsolated {
                    guard let self, let popup, self.popups.contains(where: { $0 === popup }) else { return }
                    // floating-ui's `hide` middleware: a trigger that scrolled out of the window (a recycled
                    // or removed row) takes its popup with it instead of leaving it at the host's corner.
                    guard let trigger = popup.trigger, trigger.window === self.window else {
                        self.close(popup, returnFocus: false)
                        return
                    }
                    let old = popup.container.layer.map { ($0.presentation() ?? $0).position }
                    self.reposition(popup)
                    guard popup.motion == .tooltip, !Motion.reduced, let old, let layer = popup.container.layer, layer.position != old else { return }
                    let a = CABasicAnimation(keyPath: "position")
                    a.fromValue = NSValue(point: old)
                    a.toValue = NSValue(point: layer.position)
                    a.duration = Motion.Durations.default
                    a.timingFunction = Motion.easeInOut
                    layer.add(a, forKey: "position")
                }
            })
            clip = scroll.superview?.enclosingScrollView
        }
    }

    public func close(_ popup: OpenPopup, returnFocus: Bool = true) {
        guard let index = popups.firstIndex(where: { $0 === popup }) else { return }
        closeChildren(of: popup)
        popups.remove(at: index)
        popup.anchorObservers.forEach(NotificationCenter.default.removeObserver)
        popup.anchorObservers.removeAll()
        if popup.pressesTrigger { (popup.trigger as? ControlView)?.isPopupOpen = false }
        if returnFocus, popup.returnsFocus, let trigger = popup.trigger, trigger.acceptsFirstResponder {
            window?.makeFirstResponder(trigger)
        }
        animate(popup, entering: false)
        popup.onClose?()
        if popups.isEmpty { removeMonitors() }
    }

    public func closeAll() { for popup in popups.reversed() where popups.contains(where: { $0 === popup }) { close(popup, returnFocus: false) } }

    func closeChildren(of parent: OpenPopup) {
        for popup in popups.reversed() where popup.parent === parent { close(popup, returnFocus: false) }
    }

    /// Routes a key to the topmost popup. Unhandled Escape closes it and returns focus to its trigger.
    @discardableResult
    public func handleKey(_ key: PopupKey) -> Bool {
        guard let top = popups.last(where: { !$0.isPassive }) ?? popups.last else { return false }
        if top.content.popupHandleKey(key) { return true }
        if key == .escape { close(top); return true }
        return false
    }

    /// Outside press: closes every popup whose frame and trigger miss the point. Returns true when the
    /// click should not reach the view under it.
    @discardableResult
    public func handleMouseDown(at point: CGPoint) -> Bool {
        guard !popups.isEmpty else { return false }
        if popups.contains(where: { $0.container.frame.contains(point) }) { return false }
        func onTrigger(_ p: OpenPopup) -> Bool {
            guard let t = p.trigger, t.window === window else { return false }
            return convert(t.bounds, from: t).contains(point)
        }
        if popups.contains(where: { $0.keepsOpenOnTriggerPress && onTrigger($0) }) { return false }
        let swallow = popups.contains(where: \.swallowsOutsideClick)
        let onPressedTrigger = popups.contains { $0.pressesTrigger && onTrigger($0) }
        if swallow || onPressedTrigger {
            // AppKit still sends the release to the trigger under a swallowed press; it must not reopen the popup.
            for popup in popups where onTrigger(popup) { (popup.trigger as? ControlView)?.pressClosedPopup = true }
        }
        closeAll()
        // A press on the trigger closes the popup; the trigger must not reopen it in the same click.
        return swallow || onPressedTrigger
    }

    // MARK: Events

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        // Local monitors run on the main thread; the events never leave it.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window, let key = PopupKey(event) else { return false }
                return self.handleKey(key)
            }
            return used ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window else { return false }
                return self.handleMouseDown(at: self.convert(event.locationInWindow, from: nil))
            }
            return used ? nil : event
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
    }

    // MARK: Motion

    private func animate(_ popup: OpenPopup, entering: Bool) {
        let container = popup.container
        let scale = entering ? popup.motion.enterScale : popup.motion.exitScale
        guard let scale, !Motion.reduced, window != nil, let layer = container.layer else {
            if !entering { container.removeFromSuperview() }
            return
        }
        let origin = popup.result?.transformOrigin ?? CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        var t = CATransform3DMakeTranslation(origin.x, origin.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -origin.x, -origin.y, 0)
        let small = NSValue(caTransform3D: t), identity = NSValue(caTransform3D: CATransform3DIdentity)
        CATransaction.begin()
        if !entering {
            if popup.isPassive { exitingPassive.append(container) }
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    container.removeFromSuperview()
                    self?.exitingPassive.removeAll { $0 === container }
                }
            }
        }
        let transform = CABasicAnimation(keyPath: "sublayerTransform")
        transform.fromValue = entering ? small : identity
        transform.toValue = entering ? identity : small
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = entering ? 0 : 1
        fade.toValue = entering ? 1 : 0
        for a in [transform, fade] {
            a.duration = popup.motion.duration
            a.timingFunction = Motion.easeInOut
            a.fillMode = .both
            a.isRemovedOnCompletion = entering
        }
        layer.add(transform, forKey: "popup.transform")
        layer.add(fade, forKey: "popup.opacity")
        CATransaction.commit()
    }
}

public extension NSView {
    /// The popup host of this view's window.
    var popupHost: PopupHost? { window.map(PopupHost.host(for:)) }
}
