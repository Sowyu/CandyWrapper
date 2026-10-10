import AppKit

/// T3's `.settings-slider` (apps/web/src/index.css:931-1020): a native range input drawn as a 6px
/// rounded track filled with `primary` up to the thumb, and a 16px thumb with a 2px `primary` ring on
/// `background`. 24px tall. The fill runs to the thumb's center (`--settings-slider-fill-offset`).
public final class SliderView: DSView {
    public var value: Double { didSet { if value != oldValue { needsDisplay = true; setAccessibilityValue(value) } } }
    public var range: ClosedRange<Double> { didSet { needsDisplay = true } }
    public var step: Double
    public final var onChange: (@MainActor (Double) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    public init(value: Double, range: ClosedRange<Double>, step: Double) {
        self.value = value; self.range = range; self.step = step
        super.init(frame: .zero)
        setAccessibilityRole(.slider)
        setAccessibilityValue(value)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    public override var wantsUpdateLayer: Bool { false }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var ratio: CGFloat {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
    }

    public override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.height / 2
        let track = NSRect(x: 0, y: midY - 3, width: bounds.width, height: 6)
        let thumbX = 8 + ratio * (bounds.width - 16)
        let fillEnd = ratio * bounds.width + (0.5 - ratio) * 16
        let path = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        Themed.color(\.contrastMutedForeground, 0.22).setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        Themed.color(\.primary).setFill()
        NSRect(x: 0, y: track.minY, width: max(0, fillEnd), height: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        Themed.color(\.contrastBorder, 0.55).setStroke()
        let inset = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        inset.lineWidth = 1
        inset.stroke()
        let scale: CGFloat = pressed ? 0.94 : hovering ? 1.08 : 1
        let d = 16 * scale
        let thumb = NSRect(x: thumbX - d / 2, y: midY - d / 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = hovering ? 3 : 2
        shadow.shadowColor = Themed.color(\.contrastForeground, hovering ? 0.2 : 0.12)
        shadow.set()
        Themed.color(\.background).setFill()
        NSBezierPath(ovalIn: thumb).fill()
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(ovalIn: thumb.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        Themed.color(\.primary).setStroke()
        ring.stroke()
    }

    private func set(from event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let r = min(1, max(0, (x - 8) / max(1, bounds.width - 16)))
        var v = range.lowerBound + Double(r) * (range.upperBound - range.lowerBound)
        v = (v / step).rounded() * step
        v = min(range.upperBound, max(range.lowerBound, v))
        guard v != value else { return }
        value = v
        onChange?(v)
    }

    public override func mouseDown(with event: NSEvent) { pressed = true; set(from: event) }
    public override func mouseDragged(with event: NSEvent) { set(from: event) }
    public override func mouseUp(with event: NSEvent) { pressed = false }
    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    public override func accessibilityPerformIncrement() -> Bool { nudge(step) }
    public override func accessibilityPerformDecrement() -> Bool { nudge(-step) }
    private func nudge(_ delta: Double) -> Bool {
        let v = min(range.upperBound, max(range.lowerBound, value + delta))
        guard v != value else { return false }
        value = v
        onChange?(v)
        return true
    }
}
