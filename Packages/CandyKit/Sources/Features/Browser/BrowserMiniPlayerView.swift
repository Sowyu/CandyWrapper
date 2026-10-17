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

    /// Device previews reuse the same floating shell, controls and resize math.
    public var deviceContent: DevicePanelStreamView? {
        didSet {
            oldValue?.removeFromSuperview()
            viewer.isHidden = deviceContent != nil
            if let deviceContent { clip.addSubview(deviceContent) }
            needsLayout = true
        }
    }
    public let viewer = ServerBrowserView()
    public var onOpenInPanel: (@MainActor () -> Void)?
    public var onClose: (@MainActor () -> Void)?
    /// The user dragged the player; the owner keeps the new origin.
    public var onMove: (@MainActor (CGPoint) -> Void)?

    public var onResize: ((CGSize) -> Void)?
    private let resizeHandles = BrowserMiniPlayerResizeDirection.allCases.map { BrowserMiniPlayerResizeView(direction: $0) }
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
        [card, clip, handle].forEach(addSubview)
        for resize in resizeHandles {
            addSubview(resize)
            resize.onResize = { [weak self] rect in self?.onMove?(rect.origin); self?.onResize?(rect.size) }
        }
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

    /// `previewMiniPlayerLayout.ts:150-267`: stay below the details card and above the composer,
    /// or move beside them when that is closer to the dragged position.
    public static func frame(size: CGSize, origin: CGPoint?, container: CGRect,
                             composer: CGRect? = nil, details: CGRect? = nil) -> CGRect {
        let gap = edgeGap
        let availableHeight = (composer?.minY ?? container.maxY) - container.minY - 2 * gap
        let fit = min(1, max(1, container.width - 2 * gap) / max(1, size.width),
                      max(1, availableHeight) / max(1, size.height))
        let size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let desired = origin ?? CGPoint(x: details.map { $0.maxX - size.width } ?? (container.maxX - gap - size.width),
                                        y: details.map { $0.maxY + gap } ?? (container.minY + gap))
        func clampX(_ x: CGFloat) -> CGFloat {
            min(max(container.minX + gap, x), max(container.minX + gap, container.maxX - gap - size.width))
        }
        func overlaps(_ rect: CGRect, _ obstacle: CGRect?) -> Bool {
            obstacle.map { rect.minX < $0.maxX && rect.maxX > $0.minX } ?? false
        }
        let inside = CGPoint(x: clampX(desired.x), y: min(max(container.minY + gap, desired.y),
            max(container.minY + gap, container.maxY - gap - size.height)))
        func candidate(_ x: CGFloat) -> CGRect {
            let span = CGRect(x: x, y: 0, width: size.width, height: size.height)
            let ceiling = overlaps(span, details) ? details!.maxY : container.minY
            let floor = overlaps(span, composer) ? composer!.minY : container.maxY
            let y = min(container.maxY - gap - size.height,
                        max(container.minY + gap, ceiling + gap, min(inside.y, floor - gap - size.height)))
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        func blocked(_ rect: CGRect) -> Bool {
            (overlaps(rect, details) && rect.minY < details!.maxY + gap)
                || (overlaps(rect, composer) && rect.maxY > composer!.minY - gap)
        }
        var best = candidate(inside.x)
        var distance = blocked(best) ? CGFloat.infinity : abs(best.minY - inside.y)
        for obstacle in [composer, details].compactMap({ $0 }) {
            for x in [obstacle.minX - gap - size.width, obstacle.maxX + gap] where clampX(x) == x {
                let rect = candidate(x)
                let d = abs(x - inside.x) + abs(rect.minY - inside.y)
                if !blocked(rect), d < distance { best = rect; distance = d }
            }
        }
        return best
    }

    public override func layout() {
        super.layout()
        for resize in resizeHandles {
            let d = resize.direction
            let corner = (d.north || d.south) && (d.east || d.west)
            let w: CGFloat = corner ? 12 : (d.east || d.west) ? 6 : max(0, bounds.width - 24)
            let h: CGFloat = corner ? 12 : (d.north || d.south) ? 6 : max(0, bounds.height - 24)
            resize.frame = NSRect(x: d.west ? 0 : d.east ? bounds.width - w : 12,
                                  y: d.north ? 0 : d.south ? bounds.height - h : 12, width: w, height: h)
        }
        card.frame = bounds
        clip.frame = bounds
        viewer.frame = clip.bounds
        deviceContent?.frame = clip.bounds
        // The handle sits `pillInset` (8, or 55% of the radius) from the top-right corner.
        let inset = max(8, (Self.cornerRadius * 0.55).rounded())
        let w = HandleView.pillWidth
        handle.frame = NSRect(x: bounds.width - inset - w, y: inset, width: w, height: 32)
    }

    public override func updateLayer() {
        // A preview floats above live text. Glass's muted overlay is not a backing surface.
        card.layer?.backgroundColor = Themed.color(\.background).withAlphaComponent(1).cgColor(in: self)
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
            // Both cross-fade over 150 ms on the default curve (`transition-opacity`, ThreadPreviewMiniPlayer.tsx:492,503).
            HoverReveal.fade([pill], visible: hovered)
            CATransaction.begin()
            CATransaction.setDisableActions(Motion.reduced || window == nil)
            CATransaction.setAnimationDuration(Motion.Durations.default)
            CATransaction.setAnimationTimingFunction(Motion.easeInOut)
            dot.opacity = hovered ? 0 : 1
            CATransaction.commit()
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
