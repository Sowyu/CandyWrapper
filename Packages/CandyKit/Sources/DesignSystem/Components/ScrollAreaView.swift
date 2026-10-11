import AppKit
import QuartzCore

/// T3's `ScrollArea` (`apps/web/src/components/ui/scroll-area.tsx`): a system NSScrollView with T3's overlay
/// scrollbars and optional edge fades. Scrolling stays on AppKit's path; we only restyle the scroller and,
/// within `fadeSize` of an edge, move the fade mask's stops.
/// Spec: docs/research/recovered/ui-components-b.md section 8.
public final class ScrollAreaView: DSView {
    public let scrollView = NSScrollView()
    /// `scrollFade`: each edge fades over min(fadeSize, distance scrolled from that edge).
    public var scrollFade: Bool { didSet { updateFades(force: true) } }
    /// `--fade-size`: 24px, SidebarContent uses 12px.
    public var fadeSize: CGFloat = 24 { didSet { updateFades(force: true) } }
    /// `hideScrollbars`: no scrollbars at all.
    public var hideScrollbars = false { didSet { updateScrollers() } }

    private let fadeMask = CAGradientLayer()
    private var fades: (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) = (-1, -1, -1, -1)
    private let horizontalFadeMask = CAGradientLayer()
    private var trackingArea: NSTrackingArea?
    private var hovering = false

    public init(documentView: NSView, scrollFade: Bool = false) {
        self.scrollFade = scrollFade
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller = ScrollAreaScroller()
        scrollView.horizontalScroller = ScrollAreaScroller()
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = documentView
        addSubview(scrollView)
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Selector observers are removed automatically when the view is deallocated.
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        updateScrollers()
    }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        updateFades(force: true)
    }

    /// Scrolls without animation, for restoring a position and for tests.
    public func scroll(to offset: NSPoint) {
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateFades(force: false)
    }

    /// Forces the scrollbar state for the gallery and visual tests.
    public func previewScrollbar(visible: Bool, thumbHovered: Bool = false) {
        for scroller in scrollers {
            scroller.thumbHovered = thumbHovered
            scroller.setShown(visible, animated: false)
        }
    }

    private var scrollers: [ScrollAreaScroller] {
        [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap { $0 as? ScrollAreaScroller }
    }

    private func updateScrollers() {
        scrollView.hasVerticalScroller = !hideScrollbars
        scrollView.hasHorizontalScroller = !hideScrollbars
        scrollers.forEach { $0.setShown(false, animated: false) }
    }

    // MARK: Visibility (`data-hovering`, `data-scrolling`)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        hovering = true
        scrollers.forEach { $0.setShown(true, animated: true) }
    }

    public override func mouseExited(with event: NSEvent) {
        hovering = false
        scrollers.forEach { $0.setShown(false, animated: true) }
    }

    @objc private func didScroll() {
        updateFades(force: false)
        if !hovering { scrollers.forEach { $0.flashForScroll() } }
    }

    // MARK: Fades

    private func updateFades(force: Bool) {
        guard scrollFade, let document = scrollView.documentView else {
            scrollView.contentView.layer?.mask = nil
            fades = (-1, -1, -1, -1)
            return
        }
        let clip = scrollView.contentView.bounds
        let doc = document.frame
        let maxY = max(0, doc.height - clip.height), maxX = max(0, doc.width - clip.width)
        // The clip view is flipped when the document is; offsets count from the CSS top either way.
        let y = document.isFlipped ? clip.minY : maxY - clip.minY
        let x = clip.minX
        let next = (top: min(fadeSize, max(0, y)), bottom: min(fadeSize, max(0, maxY - y)),
                    left: min(fadeSize, max(0, x)), right: min(fadeSize, max(0, maxX - x)))
        // AppKit scrolls a layer-backed clip view by moving its layer's bounds origin, so the mask, which
        // lives in that layer's space, has to follow the origin on every scroll or the rows past the
        // first screen draw blank.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        fadeMask.frame = clip
        // Only the 0...fadeSize band near each edge changes the gradient; past it the stops are constant.
        guard force || next != fades else { return }
        fades = next
        let h = max(1, clip.height), w = max(1, clip.width)
        fadeMask.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        // Layer space of a flipped clip view is y-down.
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.locations = [0, NSNumber(value: Double(next.top / h)), NSNumber(value: Double(1 - next.bottom / h)), 1]
        if next.left > 0 || next.right > 0 {
            horizontalFadeMask.frame = fadeMask.bounds
            horizontalFadeMask.colors = fadeMask.colors
            horizontalFadeMask.startPoint = CGPoint(x: 0, y: 0.5)
            horizontalFadeMask.endPoint = CGPoint(x: 1, y: 0.5)
            horizontalFadeMask.locations = [0, NSNumber(value: Double(next.left / w)), NSNumber(value: Double(1 - next.right / w)), 1]
            if horizontalFadeMask.superlayer == nil { fadeMask.addSublayer(horizontalFadeMask) }
            // ponytail: a sublayer adds to the mask instead of intersecting; exact only when one axis fades, use a drawn mask if 2D fades matter
        } else {
            horizontalFadeMask.removeFromSuperlayer()
        }
        scrollView.contentView.layer?.mask = fadeMask
    }
}

/// The overlay scrollbar: 6px pill thumb, 4px from the track ends and 1px from the edge, `--app-scrollbar-thumb`
/// (hover `--app-scrollbar-thumb-hover`). Opacity runs on Core Animation: in over 100ms, out over 150ms after 300ms.
final class ScrollAreaScroller: NSScroller {
    static let thickness: CGFloat = 6
    var thumbHovered = false { didSet { if thumbHovered != oldValue { needsDisplay = true } } }
    private var shown = false
    private var knobTracking: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        thickness + 1
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.opacity = 0
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var vertical: Bool { bounds.height >= bounds.width }

    /// Base UI's thumb: length max(16, track * visible / total), placed by the scroll fraction.
    override func rect(for partCode: NSScroller.Part) -> NSRect {
        let track = vertical ? NSRect(x: bounds.maxX - 1 - Self.thickness, y: 4, width: Self.thickness, height: bounds.height - 8)
                             : NSRect(x: 4, y: bounds.maxY - 1 - Self.thickness, width: bounds.width - 8, height: Self.thickness)
        switch partCode {
        case .knob:
            let length = vertical ? track.height : track.width
            let thumb = max(16, length * knobProportion)
            let offset = (length - thumb) * doubleValue
            return vertical ? NSRect(x: track.minX, y: track.minY + offset, width: track.width, height: thumb)
                            : NSRect(x: track.minX + offset, y: track.minY, width: thumb, height: track.height)
        case .knobSlot: return track
        default: return super.rect(for: partCode)
        }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func draw(_ dirtyRect: NSRect) { drawKnob() }

    override func drawKnob() {
        guard knobProportion < 1, knobProportion > 0 else { return }
        let rect = self.rect(for: .knob)
        let color = Themed.color(thumbHovered ? \.appScrollbarThumbHover : \.appScrollbarThumb)
        color.cgColor(in: self).asNSColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Self.thickness / 2, yRadius: Self.thickness / 2).fill()
    }

    // AppKit's own overlay fading would fight ours: keep the view's alpha at 1 and drive the layer.
    override var alphaValue: CGFloat {
        get { 1 }
        set {}
    }

    func setShown(_ visible: Bool, animated: Bool) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "flash")
        shown = visible
        let target: Float = visible ? 1 : 0
        if animated, !Motion.reduced {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
            animation.toValue = target
            animation.duration = visible ? 0.1 : 0.15
            if !visible {
                animation.beginTime = CACurrentMediaTime() + 0.3
                animation.fillMode = .backwards
            }
            animation.timingFunction = Motion.easeInOut
            layer.add(animation, forKey: "opacity")
        }
        layer.opacity = target
    }

    /// `data-scrolling`: visible while scrolling, cleared 500ms after the last movement, then the 300ms delay.
    /// One replaced keyframe animation per scroll event, no timers.
    func flashForScroll() {
        guard let layer, !shown else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let from = layer.presentation()?.opacity ?? 0
        animation.values = [from, 1, 1, 0]
        animation.keyTimes = [0, NSNumber(value: 0.1 / 0.95), NSNumber(value: 0.8 / 0.95), 1]
        animation.duration = Motion.reduced ? 0.8 : 0.95
        layer.add(animation, forKey: "flash")
        layer.opacity = 0
    }

    // MARK: Thumb hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let knobTracking { removeTrackingArea(knobTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        knobTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        thumbHovered = rect(for: .knob).contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { thumbHovered = false }
}

private extension CGColor {
    var asNSColor: NSColor { NSColor(cgColor: self) ?? .clear }
}
