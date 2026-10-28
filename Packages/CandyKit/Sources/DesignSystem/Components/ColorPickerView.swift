import AppKit

/// T3's `ColorSaturationValuePlane` (`components/ui/color-picker.tsx:65-173`): a hue fill with a white-to-clear
/// horizontal and a clear-to-black vertical gradient, and a 12px ring thumb kept 6px inside the edges.
/// Spec: docs/research/recovered/ui-components-a.md 20.
public final class ColorSaturationValuePlaneView: DSView {
    public enum Variant: String, Sendable { case inset, edge }

    public var hue: Double { didSet { needsDisplay = true } }
    public var saturation: Double { didSet { moveThumb() } }
    public var value: Double { didSet { moveThumb() } }
    public var variant: Variant { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    public final var onChange: (@MainActor (_ saturation: Double, _ value: Double) -> Void)?
    /// Keyboard focus shows the ring and the "Saturation 42%" label.
    public var showsFocus = false { didSet { needsDisplay = true; focusLabel.isHidden = !showsFocus } }

    private let focusLabel = LabelView("", font: DSFont.ui(12))

    public init(hue: Double = 210, saturation: Double = 0.6, value: Double = 0.8, variant: Variant = .inset) {
        self.hue = hue; self.saturation = saturation; self.value = value; self.variant = variant
        super.init(frame: .zero)
        layer?.masksToBounds = false
        focusLabel.lineHeight = 16
        focusLabel.isHidden = true
        addSubview(focusLabel)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Color")
    }

    public override var wantsUpdateLayer: Bool { false }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: variant == .inset ? 128 : 144) }

    private var radius: CGFloat { variant == .inset ? 10 : 0 }

    public override func layout() {
        super.layout()
        moveThumb()
        focusLabel.text = "Saturation \(Int((saturation * 100).rounded()))%"
        let w = focusLabel.textWidth
        focusLabel.frame = NSRect(x: 8 + 6, y: bounds.height - 8 - 2 - 16, width: w + 1, height: 16)
    }

    // ponytail: the thumb jumps instead of T3's 80ms linear left/top transition; move it to a CALayer if that shows
    private func moveThumb() { needsDisplay = true }

    private var thumbRect: CGRect {
        // left calc(s * (100% - .75rem) + .375rem), top calc((1 - v) * (100% - .75rem) + .375rem)
        let x = saturation * (bounds.width - 12) + 6, y = (1 - value) * (bounds.height - 12) + 6
        return CGRect(x: x - 6, y: y - 6, width: 12, height: 12)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if showsFocus {
            // `ring-2 ring-ring ring-offset-2 ring-offset-popover`
            ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: -4, dy: -4), cornerWidth: radius + 4, cornerHeight: radius + 4, transform: nil))
            ctx.setFillColor(Themed.color(\.ring).cgColor(in: self)); ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: -2, dy: -2), cornerWidth: radius + 2, cornerHeight: radius + 2, transform: nil))
            ctx.setFillColor(Themed.color(\.popover).cgColor(in: self)); ctx.fillPath()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor(NSColor(hue: hue / 360, saturation: 1, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!.cgColor)
        ctx.fill(bounds)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // CSS interpolates gradients in premultiplied sRGB, so `#fff -> transparent` is white fading out.
        let white = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(white, start: CGPoint(x: 0, y: 0), end: CGPoint(x: bounds.width, y: 0), options: [])
        let black = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(black, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: bounds.height), options: [])
        ctx.restoreGState()
        // Thumb: 12px, 2px white border, `0 0 0 1px rgb(0 0 0 / .4)` outside it, no fill.
        let t = thumbRect
        func ring(_ outer: CGRect, _ inner: CGRect, _ color: CGColor) {
            let p = CGMutablePath(); p.addEllipse(in: outer); p.addEllipse(in: inner)
            ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath(using: .evenOdd)
        }
        ring(t.insetBy(dx: -1, dy: -1), t, CGColor(gray: 0, alpha: 0.4))
        ring(t, t.insetBy(dx: 2, dy: 2), CGColor(gray: 1, alpha: 1))
        focusLabel.color = Themed.color(\.contrastPopoverForeground)
        focusLabel.layer?.backgroundColor = Themed.color(\.popover).cgColor(in: self)
        focusLabel.layer?.cornerRadius = 4
    }

    // MARK: Input

    public override func mouseDown(with event: NSEvent) { track(event) }
    public override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        saturation = min(1, max(0, (p.x - 6) / max(1, bounds.width - 12)))
        value = 1 - min(1, max(0, (p.y - 6) / max(1, bounds.height - 12)))
        onChange?(saturation, value)
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { showsFocus = NSApp.currentEvent?.type == .keyDown; return true }
    public override func resignFirstResponder() -> Bool { showsFocus = false; return true }

    /// Arrows ±0.02, Shift ±0.1, Home 0, End 1 (on saturation; up and down move value).
    public override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.02
        switch event.specialKey {
        case .leftArrow?: saturation = max(0, saturation - step)
        case .rightArrow?: saturation = min(1, saturation + step)
        case .upArrow?: value = min(1, value + step)
        case .downArrow?: value = max(0, value - step)
        case .home?: saturation = 0
        case .end?: saturation = 1
        default: super.keyDown(with: event); return
        }
        onChange?(saturation, value)
        needsLayout = true
    }
}

/// T3's `ColorHueSlider` (color-picker.tsx:175-225): a 10px rainbow track in a 24px hit area and a 16px
/// thumb filled with the hue, kept 8px inside the ends.
public final class ColorHueSliderView: DSView {
    public var hue: Double { didSet { needsDisplay = true } }
    public final var onChange: (@MainActor (Double) -> Void)?
    public var showsFocus = false { didSet { needsDisplay = true } }

    public init(hue: Double = 210) {
        self.hue = hue
        super.init(frame: .zero)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Hue")
    }

    public override var wantsUpdateLayer: Bool { false }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if showsFocus && DesignGeometry.usesClassic(self) {
            ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: -4, dy: -4), cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.setFillColor(Themed.color(\.ring).cgColor(in: self)); ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: -2, dy: -2), cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.setFillColor(Themed.color(\.popover).cgColor(in: self)); ctx.fillPath()
        }
        if showsFocus && !DesignGeometry.usesClassic(self) {
            // color-picker.tsx:199: a 2px popover offset, then the 2px inset ring.
            for (outside, inside, color) in [(CGFloat(0), CGFloat(2), Themed.color(\.popover)),
                                               (CGFloat(2), CGFloat(4), Themed.color(\.ring))] {
                let path = CGMutablePath()
                path.addPath(CGPath(roundedRect: bounds.insetBy(dx: outside, dy: outside), cornerWidth: 12 - outside, cornerHeight: 12 - outside, transform: nil))
                path.addPath(CGPath(roundedRect: bounds.insetBy(dx: inside, dy: inside), cornerWidth: 12 - inside, cornerHeight: 12 - inside, transform: nil))
                ctx.addPath(path)
                ctx.setFillColor(color.cgColor(in: self))
                ctx.fillPath(using: .evenOdd)
            }
        }
        let track = CGRect(x: 0, y: (bounds.height - 10) / 2, width: bounds.width, height: 10)
        let trackPath = CGPath(roundedRect: track, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.addPath(trackPath); ctx.clip()
        let stops: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (1, 1, 0), (0, 1, 0), (0, 1, 1), (0, 0, 1), (1, 0, 1), (1, 0, 0)]
        let colors = stops.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        let locations = (0..<7).map { CGFloat($0) / 6 }
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: track.minX, y: 0), end: CGPoint(x: track.maxX, y: 0), options: [])
        // `shadow-[inset_0_0_0_1px_rgb(0_0_0_/_12%)]`
        let ring = CGMutablePath()
        ring.addPath(trackPath)
        ring.addPath(CGPath(roundedRect: track.insetBy(dx: 1, dy: 1), cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.addPath(ring); ctx.setFillColor(CGColor(gray: 0, alpha: 0.12)); ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        // Thumb: left calc(h/360 * (100% - 1rem) + .5rem).
        let cx = hue / 360 * (bounds.width - 16) + 8, cy = bounds.midY
        let t = CGRect(x: cx - 8, y: cy - 8, width: 16, height: 16)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.4)); ctx.fillEllipse(in: t.insetBy(dx: -1, dy: -1))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillEllipse(in: t)
        ctx.setFillColor(NSColor(hue: hue / 360, saturation: 1, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!.cgColor)
        ctx.fillEllipse(in: t.insetBy(dx: 2, dy: 2))
    }

    public override func mouseDown(with event: NSEvent) { track(event) }
    public override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        hue = min(360, max(0, (x - 8) / max(1, bounds.width - 16) * 360))
        onChange?(hue)
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { showsFocus = NSApp.currentEvent?.type == .keyDown; return true }
    public override func resignFirstResponder() -> Bool { showsFocus = false; return true }

    /// Arrows ±1 degree, Shift ±10.
    public override func keyDown(with event: NSEvent) {
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.specialKey {
        case .leftArrow?, .downArrow?: hue = max(0, hue - step)
        case .rightArrow?, .upArrow?: hue = min(360, hue + step)
        default: super.keyDown(with: event); return
        }
        onChange?(hue)
    }
}
