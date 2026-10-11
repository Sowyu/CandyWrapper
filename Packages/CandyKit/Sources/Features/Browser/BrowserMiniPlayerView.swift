import AppKit
import DesignSystem

/// The floating browser over the chat (`ThreadPreviewMiniPlayer`, `MiniPlayerShell`): the tab's
/// viewer with its control bar at the bottom, 12px corners on a muted card with `shadow-2xl/35`,
/// and a dot handle in the top-right corner that turns into the pill (open in right panel, close)
/// on hover and drags the player.
public final class BrowserMiniPlayerView: DSView {
    /// `PREVIEW_MINI_PLAYER_EDGE_GAP`, `_CORNER_RADIUS`, the default box a fresh player fits into.
    public static let edgeGap: CGFloat = 12
    public static let cornerRadius: CGFloat = 12
    static let defaultBox = CGSize(width: 320, height: 320)

    public let viewer = ServerBrowserView()
    public var onOpenInPanel: (@MainActor () -> Void)?
    public var onClose: (@MainActor () -> Void)?
    /// The user dragged the player; the owner keeps the new origin.
    public var onMove: (@MainActor (CGPoint) -> Void)?

    public var onResize: ((CGSize) -> Void)?
    private let resize = BrowserMiniPlayerResizeView()
    private let card = DSView()
    private let clip = DSView()
    private let handle = HandleView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        viewer.controlPosition = .bottom
        layer?.masksToBounds = false
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.shadowOpacity = 1
        card.layer?.shadowRadius = 25
        card.layer?.shadowOffset = CGSize(width: 0, height: -25)
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.masksToBounds = true
        clip.addSubview(viewer)
        handle.onOpen = { [weak self] in self?.onOpenInPanel?() }
        handle.onClose = { [weak self] in self?.onClose?() }
        handle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.onMove?(CGPoint(x: self.frame.minX + delta.x, y: self.frame.minY + delta.y))
        }
        [card, clip, handle, resize].forEach(addSubview)
        resize.onResize = { [weak self] size in self?.onResize?(size) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Floating browser preview")
    }

    /// The player's size for a page of `source` CSS px: the largest box at its aspect ratio that
    /// fits 320x320 (`PREVIEW_MINI_PLAYER_DEFAULT_BOX`), plus the control bar.
    public static func size(source: CGSize?) -> CGSize {
        let s = source.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 16, height: 10)
        let fit = min(defaultBox.width / s.width, defaultBox.height / s.height)
        return CGSize(width: (s.width * fit).rounded(), height: (s.height * fit).rounded() + ServerBrowserView.barHeight)
    }

    /// The top-right corner of `container`, `edgeGap` in, unless the user moved it; kept inside.
    public static func frame(size: CGSize, origin: CGPoint?, container: CGRect) -> CGRect {
        let gap = edgeGap
        var o = origin ?? CGPoint(x: container.maxX - gap - size.width, y: container.minY + gap)
        o.x = min(max(container.minX + gap, o.x), container.maxX - gap - size.width)
        o.y = min(max(container.minY + gap, o.y), container.maxY - gap - size.height)
        return CGRect(origin: o, size: size)
    }

    public override func layout() {
        super.layout()
        resize.frame = NSRect(x: bounds.width - 12, y: bounds.height - 12, width: 12, height: 12)
        card.frame = bounds
        clip.frame = bounds
        viewer.frame = clip.bounds
        // The handle sits `pillInset` (8, or 55% of the radius) from the top-right corner.
        let inset = max(8, (Self.cornerRadius * 0.55).rounded())
        let w = HandleView.pillWidth
        handle.frame = NSRect(x: bounds.width - inset - w, y: inset, width: w, height: 32)
    }

    public override func updateLayer() {
        card.layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self)
        card.layer?.shadowColor = Themed.black(0.35).cgColor(in: self)
    }

    /// The 8px dot (`bg-foreground/25`) that becomes the pill on hover: `h-8 rounded-lg border
    /// bg-popover/92 p-0.5`, with the open and close buttons.
    final class HandleView: DSView {
        static let pillWidth: CGFloat = 2 + 24 + 2 + 24 + 2 + 2
        let dot = CALayer()
        let pill = DSView()
        let open = ButtonView(nil, icon: .panelRight, variant: .ghost, size: .iconXs)
        let close = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
        var onOpen: (@MainActor () -> Void)?
        var onClose: (@MainActor () -> Void)?
        var onDrag: (@MainActor (CGPoint) -> Void)?
        private var hovered = false { didSet { if hovered != oldValue { restyleHover() } } }
        private var tracking: NSTrackingArea?
        private var dragStart: NSPoint?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            dot.cornerRadius = 4
            dot.borderWidth = 1
            layer?.addSublayer(dot)
            pill.layer?.cornerRadius = 10
            pill.layer?.borderWidth = 1
            pill.alphaValue = 0
            open.toolTip = "Open in right panel"
            open.setAccessibilityLabel("Open preview in right panel")
            open.action = { [weak self] in self?.onOpen?() }
            close.toolTip = "Close floating preview"
            close.setAccessibilityLabel("Close floating preview")
            close.action = { [weak self] in self?.onClose?() }
            [open, close].forEach(pill.addSubview)
            addSubview(pill)
        }

        private func restyleHover() {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.reduced ? 0 : 0.15
                pill.animator().alphaValue = hovered ? 1 : 0
            }
            dot.opacity = hovered ? 0 : 1
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            // Only the dot catches the pointer until the pill shows.
            if !hovered, !NSRect(x: bounds.width - 12, y: 0, width: 12, height: 12).contains(local) { return nil }
            return super.hitTest(point) ?? self
        }

        override func layout() {
            super.layout()
            pill.frame = bounds
            open.frame = NSRect(x: 3, y: 4, width: 24, height: 24)
            close.frame = NSRect(x: 3 + 24 + 2, y: 4, width: 24, height: 24)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.frame = CGRect(x: bounds.width - 8, y: 0, width: 8, height: 8)
            CATransaction.commit()
        }

        override func updateLayer() {
            dot.backgroundColor = Themed.color(\.foreground, 0.25).cgColor(in: self)
            dot.borderColor = Themed.color(\.background, 0.7).cgColor(in: self)
            pill.layer?.backgroundColor = Themed.color(\.popover, 0.92).cgColor(in: self)
            pill.layer?.borderColor = Themed.color(\.border, 0.8).cgColor(in: self)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { if dragStart == nil { hovered = false } }
        private var moved = false
        override func mouseDown(with event: NSEvent) { dragStart = event.locationInWindow; moved = false }
        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let p = event.locationInWindow
            // A drag under 6px is a tap (`HANDLE_TAP_SLOP_PX`).
            guard moved || hypot(p.x - start.x, p.y - start.y) >= 6 else { return }
            moved = true
            dragStart = p
            onDrag?(CGPoint(x: p.x - start.x, y: start.y - p.y))
        }
        override func mouseUp(with event: NSEvent) { dragStart = nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
