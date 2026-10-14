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

    /// `.overlay` for T3's ScrollArea; `.native` where T3 scrolls a plain `overflow: auto` element instead.
    public let scrollbars: ScrollAreaScroller.Style

    private let fadeMask = CAGradientLayer()
    private var fades: (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) = (-1, -1, -1, -1)
    private let horizontalFadeMask = CAGradientLayer()

    /// A `.native` area scrolls vertically only.
    public init(documentView: NSView, scrollFade: Bool = false, scrollbars: ScrollAreaScroller.Style = .overlay) {
        self.scrollFade = scrollFade
        self.scrollbars = scrollbars
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
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
        let width = scrollView.contentView.bounds.width
        scrollView.frame = bounds
        // Documents that size themselves to the clip (the diff list, file trees) lay out only when asked, and
        // a new clip width doesn't ask them: a maximized panel left the diff at its old width.
        if scrollView.contentView.bounds.width != width { scrollView.documentView?.needsLayout = true }
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
        let vertical = !hideScrollbars, horizontal = !hideScrollbars && scrollbars == .overlay
        if scrollView.verticalScroller is ScrollAreaScroller {
            scrollView.hasVerticalScroller = vertical
            scrollView.hasHorizontalScroller = horizontal
        } else {
            // ponytail: a native bar here draws over the content's trailing 6px instead of narrowing it as Chromium does
            // (most of these pages keep that much padding); size documents from contentSize and pass reservesLane if one needs it
            scrollView.useT3Scrollbars(scrollbars, vertical: vertical, horizontal: horizontal, reservesLane: false)
        }
        scrollers.forEach { $0.setShown(false, animated: false) }
    }

    @objc private func didScroll() {
        updateFades(force: false)
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

/// T3's scrollbar, one class for every scroll view in the app. Colors are `--app-scrollbar-thumb` and its hover
/// (index.css:90-96, :144-145); the styles differ in geometry and in when they show.
/// - `.overlay` is ScrollArea's bar (scroll-area.tsx:85-104): a 6px pill 4px from the track ends and 1px from the
///   edge, hidden until the pointer is over the scroll view or it scrolls (in over 100ms, out over 150ms after 300ms).
/// - `.native` is Chromium's styled scrollbar on `overflow: auto` (index.css:1744-1760): a 6px lane with a 3px
///   radius thumb, drawn whenever the content overflows.
/// - `.terminal` is the terminal's own bar (terminal/ghostty/surface.ts:694-700): a 4px thumb in a 6px lane the
///   host places, 18px minimum, hover anywhere on the lane.
public class ScrollAreaScroller: NSScroller {
    public enum Style: Sendable { case overlay, native, terminal }

    static let thickness: CGFloat = 6
    /// `--app-scrollbar-width`: what a `.native` bar that reserves its lane takes from the content.
    public static let laneWidth = thickness
    public let style: Style
    /// `::-webkit-scrollbar-track` block margins (`[&::-webkit-scrollbar-track]:my-2`, CommandPaletteResults.tsx:149).
    public var trackInset: CGFloat = 0 { didSet { updateThumb() } }
    var thumbHovered = false {
        didSet {
            guard thumbHovered != oldValue else { return }
            // ScrollArea: `transition-colors` (scroll-area.tsx:100). Terminal: 120ms ease-out (surface.ts:699).
            // Chromium's scrollbar pseudo-elements don't transition.
            let fades = window != nil && !Motion.reduced && style != .native
            updateThumb(colorDuration: fades ? (style == .terminal ? 0.12 : Motion.activeDuration) : 0)
        }
    }
    /// The thumb is a layer of its own. On screen AppKit's overlay scroller doesn't call `draw(_:)` and renders
    /// `drawKnob()` into its own narrower knob layer, so a drawn thumb came out the wrong width and color.
    private let thumb = CALayer()
    /// The scroll view style this bar needs: `.legacy` reserves the lane, `.overlay` draws over the content.
    var wantedScrollerStyle: NSScroller.Style = .overlay
    private var shown = false
    private var hovering = false
    private var knobTracking: NSTrackingArea?
    private var areaTracking: NSTrackingArea?

    override public class var isCompatibleWithOverlayScrollers: Bool { true }
    /// The overlay bar sits 1px from the edge.
    override public class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        thickness + 1
    }

    public init(style: Style = .overlay) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = style == .overlay ? 0 : 1
        thumb.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(thumb)
        NotificationCenter.default.addObserver(self, selector: #selector(preferredStyleChanged),
                                               name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(style: .overlay)
        frame = frameRect
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var vertical: Bool { bounds.height >= bounds.width }

    /// Thumb length max(minimum, track * visible / total), placed by the scroll fraction.
    override public func rect(for partCode: NSScroller.Part) -> NSRect {
        let t = Self.thickness
        let track: NSRect
        switch style {
        case .overlay:
            track = vertical ? NSRect(x: bounds.maxX - 1 - t, y: 4, width: t, height: bounds.height - 8)
                             : NSRect(x: 4, y: bounds.maxY - 1 - t, width: bounds.width - 8, height: t)
        case .native, .terminal:
            // AppKit can widen an overlay scroller's frame; the lane stays the trailing 6px.
            track = vertical ? NSRect(x: bounds.maxX - t, y: trackInset, width: t, height: bounds.height - 2 * trackInset)
                             : NSRect(x: trackInset, y: bounds.maxY - t, width: bounds.width - 2 * trackInset, height: t)
        }
        switch partCode {
        case .knob:
            // Base UI's 16px; the terminal's MIN_SCROLLBAR_THUMB_HEIGHT (surface.ts:37); a styled Chromium thumb
            // with no min-height keeps at least its thickness.
            let minimum: CGFloat = switch style { case .overlay: 16; case .native: t; case .terminal: 18 }
            let length = vertical ? track.height : track.width
            let thumb = min(length, max(minimum, length * knobProportion))
            let offset = (length - thumb) * doubleValue
            let knob = vertical ? NSRect(x: track.minX, y: track.minY + offset, width: track.width, height: thumb)
                                : NSRect(x: track.minX + offset, y: track.minY, width: thumb, height: track.height)
            // `inset-x-px` (surface.ts:699).
            guard style == .terminal else { return knob }
            return vertical ? knob.insetBy(dx: 1, dy: 0) : knob.insetBy(dx: 0, dy: 1)
        case .knobSlot: return track
        default: return super.rect(for: partCode)
        }
    }

    override public func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override public func draw(_ dirtyRect: NSRect) { updateThumb() }
    override public func drawKnob() {}

    override public var doubleValue: Double { didSet { updateThumb() } }
    override public var knobProportion: CGFloat { didSet { updateThumb() } }
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateThumb()
    }
    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThumb()
    }

    private func updateThumb(colorDuration: CFTimeInterval = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        thumb.isHidden = !(knobProportion > 0 && knobProportion < 1)
        guard !thumb.isHidden else { return }
        let rect = self.rect(for: .knob)
        thumb.frame = rect
        // ScrollArea: `rounded-full`. Chromium (index.css:1756) and the terminal: 3px.
        thumb.cornerRadius = style == .overlay ? min(rect.width, rect.height) / 2 : 3
        let color = Themed.color(thumbHovered ? \.appScrollbarThumbHover : \.appScrollbarThumb).cgColor(in: self)
        if colorDuration > 0, let from = thumb.presentation()?.backgroundColor ?? thumb.backgroundColor {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = from
            fade.toValue = color
            fade.duration = colorDuration
            fade.timingFunction = style == .terminal ? CAMediaTimingFunction(name: .easeOut) : Motion.easeInOut
            thumb.add(fade, forKey: "backgroundColor")
        }
        thumb.backgroundColor = color
    }

    // AppKit's own overlay fading would fight ours: keep the view's alpha at 1 and drive the layer.
    override public var alphaValue: CGFloat {
        get { 1 }
        set {}
    }

    // MARK: Visibility (`data-hovering`, `data-scrolling`)

    override public func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if let areaTracking { superview?.removeTrackingArea(areaTracking) }
        areaTracking = nil
        if let clip = (superview as? NSScrollView)?.contentView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    override public func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard style == .overlay, let scrollView = superview as? NSScrollView else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        scrollView.addTrackingArea(area)
        areaTracking = area
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    @objc private func didScroll() {
        if !hovering { flashForScroll() }
    }

    /// AppKit puts every scroll view back on the system's style when that preference changes.
    @objc private func preferredStyleChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.superview as? NSScrollView, scrollView.scrollerStyle != self.wantedScrollerStyle else { return }
            scrollView.scrollerStyle = self.wantedScrollerStyle
        }
    }

    func setShown(_ visible: Bool, animated: Bool) {
        guard style == .overlay, let layer else { return }
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
        guard style == .overlay, let layer, !shown else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let from = layer.presentation()?.opacity ?? 0
        animation.values = [from, 1, 1, 0]
        animation.keyTimes = [0, NSNumber(value: 0.1 / 0.95), NSNumber(value: 0.8 / 0.95), 1]
        animation.duration = Motion.reduced ? 0.8 : 0.95
        layer.add(animation, forKey: "flash")
        layer.opacity = 0
    }

    // MARK: Thumb hover

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let knobTracking { removeTrackingArea(knobTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        knobTracking = area
    }

    override public func mouseEntered(with event: NSEvent) {
        if let areaTracking, event.trackingArea === areaTracking {
            hovering = true
            setShown(true, animated: true)
        } else {
            mouseMoved(with: event)
        }
    }

    override public func mouseMoved(with event: NSEvent) {
        // The terminal's lane is a `group`: hovering anywhere on it lights the thumb.
        thumbHovered = style == .terminal || rect(for: .knob).contains(convert(event.locationInWindow, from: nil))
    }

    override public func mouseExited(with event: NSEvent) {
        if let areaTracking, event.trackingArea === areaTracking {
            hovering = false
            setShown(false, animated: true)
        } else {
            thumbHovered = false
        }
    }
}

/// Chromium's styled scrollbar is 6px with nothing around it, so that is the lane it reserves.
final class NativeScroller: ScrollAreaScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        thickness
    }

    init() { super.init(style: .native) }
}

public extension NSScrollView {
    /// Gives this scroll view T3's scrollbars (`ScrollAreaScroller`). A `.native` bar that `reservesLane` narrows
    /// the content by 6px while it shows, as Chromium's classic scrollbar does. Without it the bar draws over the
    /// content's edge, for scrollers T3 gives `scrollbar-gutter-both`, whose padding already holds the lane.
    func useT3Scrollbars(_ style: ScrollAreaScroller.Style = .native, vertical: Bool = true, horizontal: Bool = false,
                         reservesLane: Bool = true) {
        let scrollerStyle: NSScroller.Style = style == .native && reservesLane ? .legacy : .overlay
        func make() -> ScrollAreaScroller {
            let scroller = style == .native ? NativeScroller() : ScrollAreaScroller(style: style)
            scroller.wantedScrollerStyle = scrollerStyle
            return scroller
        }
        if vertical { verticalScroller = make() }
        if horizontal { horizontalScroller = make() }
        hasVerticalScroller = vertical
        hasHorizontalScroller = horizontal
        autohidesScrollers = true
        self.scrollerStyle = scrollerStyle
    }
}

