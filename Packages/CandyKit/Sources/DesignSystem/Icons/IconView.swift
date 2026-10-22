import AppKit
import QuartzCore

/// Layer-backed vector icon: one CAShapeLayer per SVG element, scaled from the icon's viewBox to the view size.
/// lucide strokes are 2 viewBox units wide, so they scale with the size (1.33 px at 16 px), as in T3.
public final class IconView: NSView {
    /// Nil for an icon built from a definition, such as a file type icon.
    public let name: IconName?
    private var definition: IconDefinition
    /// The definition outside Dither: the name's lucide glyph, or the one passed in.
    private let base: IconDefinition
    /// Dither draws Hugeicons' glyph where one is mapped (IconDataHugeicons.generated.swift), lucide elsewhere.
    private var usesHugeicons = false
    /// The icon whose Hugeicons glyph Dither draws: `name`, or the lucide icon a passed-in definition draws.
    /// Looked up only once Dither shows, so other themes never build the lookup.
    private lazy var hugeiconsName: IconName? = name ?? (isBrand ? IconName.lucide(drawing: base) : nil)
    /// Fixed-color glyph: unfilled shapes stay unfilled.
    private let isBrand: Bool
    private var shapes: [(layer: CAShapeLayer, element: IconElement, path: CGPath)] = []
    /// The glyph's layers, each centered on the icon, for a motion the whole glyph runs (a spin).
    public var shapeLayers: [CAShapeLayer] { shapes.map(\.layer) }
    /// lucide's `strokeWidth` prop, in viewBox units; nil keeps the glyph's own (2).
    public var strokeWidth: CGFloat? { didSet { if strokeWidth != oldValue { relayout() } } }

    public var strokeColor: NSColor { didSet { applyColors() } }
    /// Fills `currentColor` fills, and the otherwise unfilled shapes of lucide icons.
    public var fillColor: NSColor? { didSet { applyColors() } }

    private let nominalSize: CGFloat

    public convenience init(name: IconName, size: CGFloat = 16, strokeColor: NSColor = .labelColor, fillColor: NSColor? = nil) {
        self.init(name: name, definition: name.definition, brand: name.isBrand, size: size, strokeColor: strokeColor, fillColor: fillColor)
    }

    /// An icon outside the generated set. `currentColor` resolves to `strokeColor` (or `fillColor` for fills).
    /// A lucide icon's definition (a menu glyph, a restroked chevron) still swaps to its Hugeicons glyph under Dither.
    public convenience init(definition: IconDefinition, size: CGFloat = 16, color: NSColor = .labelColor) {
        self.init(name: nil, definition: definition, brand: true, size: size, strokeColor: color, fillColor: nil)
    }

    private init(name: IconName?, definition: IconDefinition, brand: Bool, size: CGFloat, strokeColor: NSColor, fillColor: NSColor?) {
        self.name = name
        self.definition = definition
        self.base = definition
        self.isBrand = brand
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.nominalSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        if ThemeRuntime.isDither(dark: NSApp?.effectiveAppearance.isDark ?? true), let alt = hugeiconsName.flatMap(Self.ditherDefinition) {
            self.definition = alt
            usesHugeicons = true
        }
        buildShapes()
        relayout()
        applyColors()
    }

    private func buildShapes() {
        for s in shapes { s.layer.removeFromSuperlayer() }
        shapes = []
        let angle = -rotation * .pi / 180
        for element in definition.elements {
            guard let path = try? element.cgPath() else { continue }
            let l = CAShapeLayer()
            l.actions = ["path": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "opacity": NSNull(),
                         "transform": NSNull()]
            l.contentsScale = window?.backingScaleFactor ?? 2
            if rotation != 0 { l.transform = CATransform3DMakeRotation(angle, 0, 0, 1) }
            layer?.addSublayer(l)
            shapes.append((l, element, path))
        }
    }

    /// Swaps between lucide and Hugeicons as the Dither theme turns on or off for this view.
    private func syncIconSet() {
        let alt = ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? hugeiconsName.flatMap(Self.ditherDefinition) : nil
        guard (alt != nil) != usesHugeicons else { return }
        usesHugeicons = alt != nil
        definition = alt ?? base
        buildShapes()
        relayout()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: nominalSize, height: nominalSize) }

    /// Decoration: clicks go to the control or bar underneath.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    public override func layout() {
        super.layout()
        relayout()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncIconSet()
        applyColors()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        withoutActions { for s in shapes { s.layer.contentsScale = scale } }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Dither's glyph for `name`: Anthropic's mark for Claude (it shows the maker's logo, like OpenAI's for Codex),
    /// else the Hugeicons glyph.
    nonisolated static func ditherDefinition(_ name: IconName) -> IconDefinition? {
        name == .brandClaudeAI ? anthropicMark : name.hugeiconsDefinition
    }
    /// Anthropic's "A" mark, filled in the current color.
    nonisolated static let anthropicMark = IconDefinition(viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24), elements: [
        IconElement(.path(d: "M17.3041 3.541h-3.6718l6.696 16.918H24Zm-10.6082 0L0 20.459h3.7442l1.3693-3.5527h7.0052l1.3693 3.5528h3.7442L10.5363 3.5409Zm-.3712 10.2232 2.2914-5.9456 2.2914 5.9456Z"),
                    IconPaint(fill: .current, stroke: .none, evenOdd: false)),
    ])

    /// Dither's glyph sizes: whatever box a call site gives, a row, menu or badge glyph draws at 14 and a toolbar glyph
    /// at 16, centered on its box, so neighbours match. Other sizes (8, 10, 18 and up) keep their box.
    nonisolated static func ditherGlyphSize(box: CGFloat) -> CGFloat {
        switch box {
        case 11...14: 14
        case 14..<17: 16
        default: box
        }
    }
    /// Dither's one stroke, in points at every glyph size; per-call `strokeWidth` overrides don't apply.
    nonisolated static let ditherStroke: CGFloat = 1.2

    private func relayout() {
        let vb = definition.viewBox
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0, vb.width > 0, vb.height > 0 else { return }
        let box = min(w, h)
        let glyph = usesHugeicons ? Self.ditherGlyphSize(box: box) : box
        let scale = usesHugeicons ? glyph / max(vb.width, vb.height) : min(w / vb.width, h / vb.height)
        let ox = (w - vb.width * scale) / 2, oy = (h - vb.height * scale) / 2
        withoutActions {
            for s in shapes {
                // viewBox (y down) -> layer (y up)
                var t = CGAffineTransform(translationX: ox, y: h - oy)
                    .scaledBy(x: scale, y: -scale)
                    .translatedBy(x: -vb.x + s.element.paint.offsetX, y: -vb.y + s.element.paint.offsetY)
                // bounds and position, not frame: frame is undefined while `rotation` turns the layer.
                s.layer.bounds = bounds
                s.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
                s.layer.path = s.path.copy(using: &t)
                if usesHugeicons {
                    s.layer.lineWidth = Self.ditherStroke
                    // The duotone tint only on large glyphs: at row and toolbar sizes it made closed shapes (a clock)
                    // read heavier than open ones (a check).
                    s.layer.isHidden = glyph <= 16 && s.element.paint.isTint
                } else {
                    s.layer.lineWidth = (strokeWidth ?? s.element.paint.strokeWidth) * scale
                    s.layer.isHidden = false
                }
            }
        }
    }

    // MARK: Rotation

    /// How a rotation change moves.
    public enum RotationMotion {
        /// Snap, for configuring a reused view or a first layout.
        case none
        /// CSS `transition-transform`: `duration` on Tailwind's default curve.
        case ease(CFTimeInterval)
        /// `MorphIcon` (`morphicons` 1.7.1) between two shapes that differ only by a turn, such as
        /// chevron-right and chevron-down. The library fits the turn and runs its default "snappy"
        /// spring, stiffness 420 and damping 30 at mass 1 (bundle `MorphIcon-*.js`, `K.snappy`).
        case morph
    }

    /// Degrees, clockwise like CSS `rotate-90`, about the icon's center.
    public private(set) var rotation: CGFloat = 0

    /// `transition-transform` with `rotate-90` or `rotate-180`. Instant under Reduce Motion or offscreen.
    public func setRotation(_ degrees: CGFloat, motion: RotationMotion = .ease(0.15)) {
        guard degrees != rotation else { return }
        rotation = degrees
        // Shape layers draw y up, so a clockwise turn on screen is a negative z rotation.
        let angle = -degrees * .pi / 180
        withoutActions {
            for s in shapes {
                let l = s.layer
                switch motion {
                case .none: break
                case _ where window == nil || Motion.reduced: break
                case .ease(let duration):
                    Motion.animate(l, keyPath: "transform.rotation.z", to: angle, duration: duration)
                case .morph:
                    let spring = CASpringAnimation(keyPath: "transform.rotation.z")
                    spring.fromValue = l.presentation()?.value(forKeyPath: "transform.rotation.z") ?? l.value(forKeyPath: "transform.rotation.z")
                    spring.toValue = angle
                    spring.mass = 1
                    spring.stiffness = 420
                    spring.damping = 30
                    spring.duration = spring.settlingDuration
                    l.add(spring, forKey: "transform.rotation.z")
                }
                l.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            }
        }
    }

    private func resolve(_ c: IconColor, fillSlot: Bool) -> CGColor? {
        let color: NSColor?
        switch c {
        case .none: color = (fillSlot && !isBrand) ? fillColor : nil
        case .current: color = fillSlot ? (fillColor ?? strokeColor) : strokeColor
        case .rgba(let v):
            color = NSColor(
                srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        }
        guard let color else { return nil }
        var out: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }

    private func applyColors() {
        // `transition-colors`: stroke and fill fade from what is on screen now.
        let fades = Motion.activeTransitions.contains(.color) && window != nil
        let shown = fades ? shapes.map { s -> (CGColor?, CGColor?) in
            let l = s.layer.presentation() ?? s.layer
            return (l.strokeColor, l.fillColor)
        } : []
        defer {
            for (s, old) in zip(shapes, shown) {
                for (key, from, to) in [("strokeColor", old.0, s.layer.strokeColor), ("fillColor", old.1, s.layer.fillColor)]
                where from != nil && to != nil && from != to {
                    let a = CABasicAnimation(keyPath: key)
                    a.fromValue = from
                    a.toValue = to
                    a.duration = Motion.activeDuration
                    a.timingFunction = Motion.easeInOut
                    s.layer.add(a, forKey: key)
                }
            }
        }
        withoutActions {
            for s in shapes {
                let p = s.element.paint
                let l = s.layer
                l.fillColor = resolve(p.fill, fillSlot: true)
                l.strokeColor = resolve(p.stroke, fillSlot: false)
                l.fillRule = p.evenOdd ? .evenOdd : .nonZero
                l.opacity = Float(p.opacity)
                l.lineCap = switch p.lineCap { case .butt: .butt; case .round: .round; case .square: .square }
                l.lineJoin = switch p.lineJoin { case .miter: .miter; case .round: .round; case .bevel: .bevel }
            }
        }
    }
}
