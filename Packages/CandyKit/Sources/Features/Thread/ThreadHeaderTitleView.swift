import AppKit
import DesignSystem

/// ChatHeader.tsx:58-73, 179-216: click opens actions, double-click edits the title.
final class ThreadHeaderTitleView: DSView {
    var onMenu: ((NSEvent, NSView) -> Void)?
    var onRename: (() -> Void)?
    private var pending: DispatchWorkItem?
    private let chevron = IconView(name: .chevronDown, size: 14)
    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.alphaValue = 0
        chevron.strokeColor = Themed.color(\.mutedForeground)
        addSubview(chevron)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func layout() { super.layout(); chevron.frame = NSRect(x: bounds.width - 14, y: 3, width: 14, height: 14) }
    // `opacity-0 transition-opacity group-hover/thread-title:opacity-100` (ChatHeader.tsx:338-342).
    override func mouseEntered(with event: NSEvent) { HoverReveal.fade([chevron], visible: true) }
    override func mouseExited(with event: NSEvent) { HoverReveal.fade([chevron], visible: false) }
    func cancelPendingMenu() { pending?.cancel(); pending = nil }
    override func mouseDown(with event: NSEvent) {
        pending?.cancel()
        if convert(event.locationInWindow, from: nil).x >= bounds.width - 18 { onMenu?(event, self); return }
        if event.clickCount > 1 {
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { onRename?() }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onMenu?(event, self)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    override func rightMouseDown(with event: NSEvent) { pending?.cancel(); onMenu?(event, self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { pending?.cancel() } }
    /// The breadcrumb group VoiceOver reads this button in (ThreadHeaderView).
    weak var accessibilityGroup: NSAccessibilityElement?
    override func accessibilityParent() -> Any? { accessibilityGroup ?? super.accessibilityParent() }
}

/// The parent thread crumb (ChatHeader.tsx:343-375 in 2994): the parent's title in `text-muted-foreground`,
/// `hover:text-foreground transition-colors`, a tooltip with the title on top, and a click opens the parent.
/// `collapsed` swaps the title for "..." when the whole breadcrumb doesn't fit (:130-164).
final class ThreadHeaderParentCrumb: ControlView {
    let label = LabelView("", font: TL.font(14, .medium), color: TL.c(\.mutedForeground))
    let ellipsis = LabelView("...", font: TL.font(14, .medium), color: TL.c(\.mutedForeground))
    private var tooltip: TooltipController?
    weak var accessibilityGroup: NSAccessibilityElement?
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            label.text = title
            tooltip?.text = title
            setAccessibilityLabel("Open parent thread: \(title)")
        }
    }
    var collapsed = false { didSet { label.isHidden = collapsed; ellipsis.isHidden = !collapsed } }
    var fullWidth: CGFloat { ceil(label.textWidth) }
    var width: CGFloat { collapsed ? ceil(ellipsis.textWidth) : fullWidth }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        transitions = .colors
        for l in [label, ellipsis] { l.lineHeight = 20; addSubview(l) }
        ellipsis.isHidden = true
        tooltip = TooltipController.attach(to: self, text: "", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
    }
    override func layout() {
        super.layout()
        label.frame = bounds
        ellipsis.frame = bounds
    }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        let color = state.hovered ? TL.c(\.foreground) : TL.c(\.mutedForeground)
        label.color = color
        ellipsis.color = color
    }
    override func accessibilityParent() -> Any? { accessibilityGroup ?? super.accessibilityParent() }
}
