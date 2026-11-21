import AppKit

/// T3's `TooltipPopup` (`tooltip.tsx`). Desktop values. Spec: docs/research/recovered/ui-components-a.md 15.
/// Redesign draws its own solid surface: the raised fill, the hairline rim, the control corner and the floating shadow.
public final class TooltipView: DSView, PopupContent {
    public enum Variant: Sendable { case `default`, glass, code }

    public let variant: Variant
    private let decoration = BoxDecorationLayer()
    private let dropShadow = PopupShadowLayer()
    private let label = LabelView()
    /// The shortcut as a group of small key caps at the right, one per modifier and one for the key.
    private var caps: [KbdView] = []
    public var frostRadius: CGFloat { DesignGeometry.radius(8, in: self) }

    public init(_ text: String, variant: Variant = .default, shortcut: String? = nil) {
        self.variant = variant
        super.init(frame: .zero)
        decoration.host = self
        dropShadow.host = self
        layer?.addSublayer(dropShadow)
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        applySurface()
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
        self.shortcut = shortcut
        buildCaps()
    }

    private var dither: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }

    private func applySurface() {
        if dither {
            var box = BoxStyle()
            box.radius = RedesignTokens.Radius.control
            box.fill = Themed.color(light: \.card, 1, dark: \.surfaceRaised, 1)
            box.border = RedesignTokens.Surface.rim(dark: effectiveAppearance.isDark)
            decoration.boxStyle = box
            dropShadow.radius = RedesignTokens.Radius.control
            dropShadow.shadows = [RedesignTokens.Shadow.floating.box]
            return
        }
        let look = (variant == .glass ? PopupSurface.tooltipGlass : .tooltip).split(radius: DesignGeometry.radius(8, in: self))
        decoration.boxStyle = look.box
        dropShadow.radius = DesignGeometry.radius(8, in: self)
        dropShadow.shadows = look.shadows
    }

    public var text: String {
        get { label.text }
        set { label.text = newValue; wrapped?.text = newValue; invalidateIntrinsicContentSize(); needsLayout = true }
    }

    public var shortcut: String? { didSet { if shortcut != oldValue { buildCaps() } } }

    private func buildCaps() {
        caps.forEach { $0.removeFromSuperview() }
        caps = Self.keys(shortcut).map { key in
            let cap = KbdView(key)
            cap.compact = true
            addSubview(cap)
            return cap
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// "⇧⌘I" is three caps, "Esc" one: each leading modifier glyph gets its own cap, the rest is the key.
    static func keys(_ shortcut: String?) -> [String] {
        guard let shortcut, !shortcut.isEmpty else { return [] }
        var keys: [String] = []
        var rest = Substring(shortcut)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first), rest.count > 1 { keys.append(String(first)); rest = rest.dropFirst() }
        if !rest.isEmpty { keys.append(String(rest)) }
        return keys
    }

    private static let capGap: CGFloat = 2
    private static let capLead: CGFloat = 8
    private var capsWidth: CGFloat {
        guard !caps.isEmpty else { return 0 }
        return caps.reduce(0) { $0 + $1.intrinsicContentSize.width } + CGFloat(caps.count - 1) * Self.capGap + Self.capLead
    }

    /// Text past the max width wraps, balanced (`text-balance wrap-anywhere`): T3's `max-w-80` (`max-w-120` for code),
    /// 260 in Redesign. One-line tooltips keep the label; the block exists only once a long text needs it.
    private var maxText: CGFloat { (variant == .code ? 480 : dither ? 260 : 320) - 18 - capsWidth }
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
        guard wraps else { return NSSize(width: label.textWidth + 18 + capsWidth, height: (label.lineHeight ?? 16.5) + 10) }
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
        return NSSize(width: width + 18 + capsWidth, height: block.height(forWidth: maxText) + 10)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        dropShadow.update(boxSize: bounds.size)
        let frame = NSRect(x: 9, y: 5, width: bounds.width - 18 - capsWidth, height: bounds.height - 10)
        label.isHidden = wraps
        wrapped?.isHidden = !wraps
        if wraps { wrappedBlock().frame = frame } else { label.frame = frame }
        // The caps sit on the first line, at the right.
        var x = bounds.width - 9
        let line = label.lineHeight ?? 16.5
        for cap in caps.reversed() {
            let size = cap.intrinsicContentSize
            x -= size.width
            cap.frame = NSRect(x: x, y: (isFlipped ? 5 : bounds.height - 5 - line) + (line - size.height) / 2, width: size.width, height: size.height)
            x -= Self.capGap
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        dropShadow.update(boxSize: bounds.size)
        applySurface()
    }
}

/// Settings > General > Tooltips.
public enum TooltipMode: String, Sendable, CaseIterable {
    case on, delayed, off
}

/// The timing every tooltip shares: one delay timer, the warm group, the dismissal events and the setting.
///
/// A tooltip opens after the pointer rests `delay` on its control (base-ui's 600ms, docs/research/recovered/
/// ui-components-a.md 15). Moving to another control within `warmWindow` of the last one closing opens the next at
/// once and without motion (base-ui's Provider `timeout`, 400ms). A mouse down, key down, scroll, pinch, drag, the
/// window losing key or ⌘⇧ held (a screenshot) closes it and keeps that control quiet until the pointer leaves it.
///
/// Idle cost is zero: the timer runs only while the pointer rests on a control that has a tooltip, and the event
/// monitor exists only while a tooltip is waiting or shown.
@MainActor
public enum Tooltips {
    /// The Settings choice, read each time a tooltip arms, so a change applies at once.
    public static var mode: () -> TooltipMode = { .on }
    /// base-ui's Tooltip.Provider `timeout` (`timeout:r=400`).
    public static let warmWindow: TimeInterval = 0.4
    /// Settings > Tooltips > Delayed.
    public static let delayedDelay: TimeInterval = 1.2

    static var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    static var schedule: (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }
    /// The pointer is on `view` itself, not on a modal or sheet drawn over it. Tracking areas ignore what covers them.
    static var pointerIsOn: (NSView) -> Bool = { view in
        guard let window = view.window, let frame = window.contentView?.superview,
              let hit = frame.hitTest(window.mouseLocationOutsideOfEventStream) else { return false }
        return hit === view || hit.isDescendant(of: view) || view.isDescendant(of: hit)
    }

    static var lastClosed: TimeInterval = -.infinity
    private(set) static weak var armed: TooltipController?
    static weak var shown: TooltipController?
    private static var timer: DispatchWorkItem?
    nonisolated(unsafe) private static var monitor: Any?
    private static var observers: [NSObjectProtocol] = []
    static var isMonitoring: Bool { monitor != nil }
    static var isTimerArmed: Bool { timer != nil }

    /// The wait before a tooltip with `delay` opens and whether it opens without motion; nil when it never opens.
    static func wait(delay: TimeInterval, mode: TooltipMode, now: TimeInterval) -> (wait: TimeInterval, instant: Bool)? {
        if mode == .off { return nil }
        if now - lastClosed < warmWindow { return (0, true) }
        return (mode == .delayed ? max(delay, delayedDelay) : delay, false)
    }

    /// The pointer came to rest on `c`'s control.
    static func arm(_ c: TooltipController) {
        cancelTimer()
        if let shown, shown !== c { shown.hide() }
        guard let w = wait(delay: c.delay, mode: c.interactive ? .on : mode(), now: now()) else { return sync() }
        armed = c
        if w.wait == 0 {
            fire(instant: w.instant)
        } else {
            let work = DispatchWorkItem { MainActor.assumeIsolated { fire(instant: w.instant) } }
            timer = work
            schedule(w.wait, work)
        }
        sync()
    }

    static func fire(instant: Bool) {
        timer = nil
        guard let c = armed else { return }
        armed = nil
        if c.mayOpen() { c.show(instant: instant) }
        sync()
    }

    /// The pointer left `c`'s control.
    static func disarm(_ c: TooltipController) {
        if armed === c { cancelTimer(); armed = nil }
        sync()
    }

    /// Closes the tooltip at once and keeps its control quiet until the pointer leaves it. Cools the warm group.
    public static func dismiss() {
        armed?.suppressed = true
        shown?.suppressed = true
        cancelTimer()
        armed = nil
        shown?.hide()
        lastClosed = -.infinity
        sync()
    }

    static func didClose(_ c: TooltipController) {
        if shown === c { shown = nil }
        lastClosed = now()
        sync()
    }

    private static func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    static func handle(_ event: NSEvent) {
        if event.type == .flagsChanged, !event.modifierFlags.contains([.command, .shift]) { return }
        // A hover card takes clicks and scrolls inside it.
        if event.type != .flagsChanged, event.type != .keyDown, let card = shown, card.interactive,
           let container = card.popup?.container, container.window === event.window,
           container.bounds.contains(container.convert(event.locationInWindow, from: nil)) { return }
        dismiss()
    }

    /// Installs the monitor while a tooltip waits or shows, and removes it otherwise.
    static func sync() {
        let needed = armed != nil || shown != nil
        if needed, monitor == nil {
            let types: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel,
                                                .magnify, .leftMouseDragged, .rightMouseDragged, .flagsChanged]
            monitor = NSEvent.addLocalMonitorForEvents(matching: types) { event in
                MainActor.assumeIsolated { handle(event) }
                return event
            }
            let center = NotificationCenter.default
            observers = [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification].map {
                center.addObserver(forName: $0, object: nil, queue: .main) { _ in MainActor.assumeIsolated { dismiss() } }
            }
        } else if !needed, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }

    /// Clears the shared state; tests only.
    static func reset() {
        cancelTimer()
        armed = nil
        shown?.hide()
        shown = nil
        lastClosed = -.infinity
        sync()
    }
}

/// Shows a tooltip while the pointer rests on a view. Timing, dismissal and the setting live in `Tooltips`.
@MainActor
public final class TooltipController: NSResponder, HoverSyncClient {
    public var text: String { didSet { if text != oldValue { syncAccessibility(); refresh() } } }
    /// Drawn as key caps at the right of the text.
    public var shortcut: String? { didSet { if shortcut != oldValue { refresh() } } }
    public var variant: TooltipView.Variant
    public var placement: PopupPlacement
    public var delay: TimeInterval
    public var closeDelay: TimeInterval
    /// Shows only while this holds, checked as the tooltip opens: a label's full text only while it is truncated.
    public var when: (() -> Bool)?
    /// The text read as the tooltip opens, nil to stay closed: a label's own text while it is truncated.
    public var liveText: (() -> String?)?
    /// Built only when shown; custom cards share the tooltip lifetime and placement.
    public var content: (() -> (NSView & PopupContent))?
    /// A card you can move onto: it waits a moment after the pointer leaves the trigger and stays open while the
    /// pointer is over it.
    public var interactive = false
    /// Shows only under Redesign, where it is also the control's accessibility label; the default themes keep T3's
    /// buttons, which have none.
    public var redesignOnly = false { didSet { syncAccessibility() } }
    /// Read each time the tooltip opens, so a rebound shortcut shows.
    public var textProvider: (@MainActor () -> String)?
    /// The shortcut read each time the tooltip opens, drawn as key caps.
    public var shortcutProvider: (@MainActor () -> String?)?

    weak var view: NSView?
    private var tracking: NSTrackingArea?
    private var pendingClose: DispatchWorkItem?
    private(set) var popup: OpenPopup?
    /// Dismissed by a click, key or scroll: quiet until the pointer leaves the control.
    var suppressed = false
    /// The help string this controller set, so clearing the text clears only its own.
    private var setHelp: String?

    /// Attaches to `view` and stays alive as long as the view does. Prefer `view.tooltip` or `view.setTooltip`.
    @discardableResult
    public static func attach(to view: NSView, text: String, shortcut: String? = nil, variant: TooltipView.Variant = .default,
                              placement: PopupPlacement = .tooltip, delay: TimeInterval = 0.6, closeDelay: TimeInterval = 0) -> TooltipController {
        if let old = controller(for: view) { old.detach() }
        let c = TooltipController(view: view, text: text, variant: variant, placement: placement, delay: delay, closeDelay: closeDelay)
        c.shortcut = shortcut
        objc_setAssociatedObject(view, &associationKey, c, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return c
    }

    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    static func controller(for view: NSView) -> TooltipController? {
        objc_getAssociatedObject(view, &associationKey) as? TooltipController
    }

    /// The tooltip text attached to `view`, for its accessibility label.
    static func text(for view: NSView) -> String? {
        guard let c = controller(for: view), !c.text.isEmpty else { return nil }
        if c.redesignOnly, !ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark) { return nil }
        return c.textProvider?() ?? c.text
    }

    /// A Redesign-only tooltip's text while Redesign shows, which then replaces the control's accessibility label.
    static func redesignText(for view: NSView) -> String? {
        guard let c = controller(for: view), c.redesignOnly else { return nil }
        return text(for: view)
    }

    /// Attaches a Redesign-only tooltip naming `action`, with `shortcut()` as key caps when it returns one; VoiceOver
    /// hears "action (shortcut)". Calling it again on the same view, as a row's update does, retitles the one attached.
    @discardableResult
    public static func redesign(_ view: NSView, _ action: String, shortcut: (@MainActor () -> String?)? = nil) -> TooltipController {
        let c = controller(for: view) ?? attach(to: view, text: action)
        c.text = action
        c.redesignOnly = true
        c.shortcutProvider = shortcut
        c.textProvider = nil
        if let shortcut { c.textProvider = { shortcut().map { "\(action) (\($0))" } ?? action } }
        return c
    }

    init(view: NSView, text: String, variant: TooltipView.Variant, placement: PopupPlacement, delay: TimeInterval, closeDelay: TimeInterval) {
        self.view = view; self.text = text; self.variant = variant; self.placement = placement
        self.delay = delay; self.closeDelay = closeDelay
        super.init()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        view.addTrackingArea(area)
        tracking = area
        syncAccessibility()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func detach() {
        hide()
        Tooltips.disarm(self)
        if let tracking { view?.removeTrackingArea(tracking) }
        tracking = nil
        text = ""
        if let view { objc_setAssociatedObject(view, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The same words stay the control's accessibility help, as the native tooltip's were.
    private func syncAccessibility() {
        guard let view, content == nil, liveText == nil else { return }
        let current = view.accessibilityHelp()
        guard current == nil || current == setHelp else { return }
        // A Redesign-only tooltip is the control's label under Redesign instead.
        setHelp = text.isEmpty || redesignOnly ? nil : text
        view.setAccessibilityHelp(setHelp)
    }

    private func refresh() {
        guard let tip = popup?.content as? TooltipView else { return }
        if text.isEmpty { return hide() }
        let (words, keys) = shownParts(dither: view.map { ThemeRuntime.isDither(dark: $0.effectiveAppearance.isDark) } ?? false)
        tip.text = words
        tip.shortcut = keys
        if let host = popup?.container.superview as? PopupHost, let popup { host.reposition(popup) }
    }

    public override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["popup"] != nil { pendingClose?.cancel(); pendingClose = nil; return }
        pointerEntered()
    }
    public override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["popup"] != nil { return pointerLeft() }
        pointerExitedControl()
    }

    /// The pointer left the control itself: a dismissed tooltip may open again on the next rest.
    func pointerExitedControl() {
        suppressed = false
        pointerLeft()
    }

    func pointerEntered() {
        pendingClose?.cancel(); pendingClose = nil
        guard !suppressed, popup == nil else { return }
        Tooltips.arm(self)
    }

    func pointerLeft() {
        Tooltips.disarm(self)
        guard interactive else { return hide() }
        pendingClose?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(closeDelay, 0.2), execute: work)
    }

    /// The checks a hover-opened tooltip passes; `show` itself opens unconditionally for code that asks for it.
    func mayOpen() -> Bool {
        guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor, !suppressed else { return false }
        if redesignOnly, !ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark) { return false }
        if let when, !when() { return false }
        if let liveText {
            guard let live = liveText(), !live.isEmpty else { return false }
            text = live
        }
        if NSEvent.modifierFlags.contains([.command, .shift]) { return false }
        // Never under a menu, popover or picker opening over the control, unless the control lives in it.
        if let host = view.popupHost, host.popups.contains(where: { !$0.isPassive && !view.isDescendant(of: $0.container) }) { return false }
        return Tooltips.pointerIsOn(view)
    }

    public var isShown: Bool { popup != nil }

    public func show(instant: Bool = false) {
        guard popup == nil, let view else { return }
        let dither = ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark)
        if redesignOnly, !dither { return }
        if let shortcutProvider { shortcut = shortcutProvider() } else if let textProvider { text = textProvider() }
        guard !text.isEmpty || content != nil, !view.isHiddenOrHasHiddenAncestor, let host = view.popupHost else { return }
        if dither, host.popups.contains(where: { $0.trigger === view && !$0.isPassive }) { return }
        let (words, keys) = shownParts(dither: dither)
        let tip = content?() ?? TooltipView(words, variant: variant, shortcut: keys)
        // Redesign puts tooltips under their control, flipping above when the window has no room.
        var place = placement
        if dither, content == nil, place.side == .top { place.side = .bottom }
        popup = host.open(tip, trigger: view, placement: place, motion: instant ? .none : .tooltip,
                          pressesTrigger: false, returnsFocus: false, passive: true)
        Tooltips.shown = self
        popup?.onClose = { [weak self] in
            guard let self else { return }
            self.popup = nil
            Tooltips.didClose(self)
        }
        Tooltips.sync()
        if interactive, let card = popup?.container {
            card.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                owner: self, userInfo: ["popup": true]))
        }
    }

    /// Redesign draws a T3-style "Action (⌘J)" as the action and key caps, both as it opens and when the text changes
    /// while it shows; the default themes keep T3's text.
    func shownParts(dither: Bool) -> (String, String?) {
        if dither, shortcut == nil, let split = Self.splitShortcut(text) { return split }
        return (text, shortcut)
    }

    /// "Toggle terminal (⌘J)" is ("Toggle terminal", "⌘J"): a trailing shortcut in parentheses, nil for other text.
    static func splitShortcut(_ text: String) -> (String, String)? {
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else { return nil }
        let keys = String(text[open.upperBound..<text.index(before: text.endIndex)])
        let named: Set<String> = ["Esc", "Return", "Tab", "Space", "Delete", "Enter"]
        let modified = keys.first.map { "⌃⌥⇧⌘".contains($0) } ?? false
        guard named.contains(keys) || (modified && keys.count <= 8 && !keys.contains(" ")) else { return nil }
        return (String(text[..<open.lowerBound]), keys)
    }

    public func hide() {
        pendingClose?.cancel()
        pendingClose = nil
        guard let popup, let host = popup.container.superview as? PopupHost else { return }
        host.close(popup, returnFocus: false)
    }
}

public extension NSView {
    /// The tooltip text `setTooltip` gave this view.
    var currentTooltip: String? { TooltipController.text(for: self) }

    /// The one way to give a view a tooltip, drawn in the app's window by `TooltipController`; nil or empty removes
    /// it. The shortcut draws as key caps, like "Agent images" with "⇧⌘I". `when` keeps it closed while it returns
    /// false, checked as the tooltip opens. The words also become the view's accessibility help.
    /// NativeTooltipGuardTests fails on AppKit's own `toolTip`.
    func setTooltip(_ text: String?, shortcut: String? = nil, when: (() -> Bool)? = nil) {
        if let c = TooltipController.controller(for: self) {
            c.text = text ?? ""
            c.shortcut = shortcut
            c.when = when
            if text?.isEmpty ?? true { c.hide() }
        } else if let text, !text.isEmpty {
            TooltipController.attach(to: self, text: text, shortcut: shortcut).when = when
        }
    }
}

public extension NSView {
    /// A tooltip whose text is read as it opens, closed while `text` returns nil: the full value of text drawn cut
    /// short. It sets no accessibility help, since the view's own text reaches VoiceOver.
    func setLiveTooltip(_ text: @escaping () -> String?) {
        let c = TooltipController.controller(for: self) ?? TooltipController.attach(to: self, text: "")
        c.liveText = text
    }

    /// Removes the tooltip and its tracking area.
    func removeTooltip() { TooltipController.controller(for: self)?.detach() }
}

public extension LabelView {
    /// Shows the full text as the tooltip only while the label draws it cut short.
    /// The label's own text already reaches VoiceOver, so this sets no accessibility help.
    func tooltipWhenTruncated() {
        setLiveTooltip { [weak self] in self.flatMap { $0.isTruncated ? $0.text : nil } }
    }
}
