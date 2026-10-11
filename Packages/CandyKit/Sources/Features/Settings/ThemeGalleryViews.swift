import AppKit
import CoreImage
import DesignSystem

/// A theme card's preview colors per appearance (ThemePreviewCircles.tsx `ThemeCardDefinition`).
public struct ThemeCardDefinition: Equatable, Sendable {
    public struct Preview: Equatable, Sendable {
        public var mode: ThemeAppearance
        /// sidebar, canvas, surface, accentSurface, accent, messageSurface, messageAction (CSS colors).
        public var colors: [ThemeColorRole: String]
    }
    /// nil for the standard T3 Code card.
    public var id: String?
    public var label: String
    public var previews: [Preview]

    static let previewRoles: [ThemeColorRole] = [.sidebar, .canvas, .surface, .accentSurface, .accent, .messageSurface, .messageAction]

    /// `STANDARD_THEME_CARDS` (ThemePreviewCircles.tsx:39-68, themePreview.ts:9-21).
    public static let standard = ThemeCardDefinition(id: nil, label: "T3 Code", previews: [
        Preview(mode: .light, colors: [.sidebar: "#fafafa", .surface: "#ffffff", .accentSurface: "#f4f4f5", .messageSurface: "#e4e4e7",
                                       .canvas: "#fcfcfc", .accent: "#f4f4f5", .messageAction: "#4f46e5"]),
        Preview(mode: .dark, colors: [.sidebar: "#0f0f10", .surface: "#121212", .accentSurface: "#27272a", .messageSurface: "#27272a",
                                      .canvas: "#0a0a0a", .accent: "#1c1c1f", .messageAction: "#8b9cff"]),
    ])

    /// `getThemeCardDefinition` (ThemePreviewCircles.tsx:77-97).
    public init(_ theme: ThemeDefinition) {
        id = theme.id
        label = theme.label
        previews = theme.modes.map { mode in
            let c = theme.colors(for: mode) ?? theme.colors
            return Preview(mode: mode, colors: c.filter { Self.previewRoles.contains($0.key) })
        }
    }

    init(id: String?, label: String, previews: [Preview]) { self.id = id; self.label = label; self.previews = previews }

    /// `previewColorsOf`, falling back to the first preview.
    public func colors(_ mode: ThemeAppearance) -> [ThemeColorRole: String] {
        (previews.first { $0.mode == mode } ?? previews[0]).colors
    }
}

/// `ThemePreviewCircle` (ThemePreviewCircles.tsx:118-170): a 56px ball, a `border-2 border-background` ring around
/// a blurred base with an accent glow and an action tint (themePreview.ts render specs). The ball is drawn once
/// into an image per colors and scale.
final class ThemePreviewCircleView: DSView {
    var colors: [ThemeColorRole: String] = [:] { didSet { if colors != oldValue { image = nil; needsDisplay = true } } }
    var mode: ThemeAppearance = .light { didSet { if mode != oldValue { image = nil; needsDisplay = true } } }
    private var image: CGImage?
    private var imageScale: CGFloat = 0

    override var wantsUpdateLayer: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 60, height: 60) }

    struct Spec { let baseTarget: String; let accentCenter: CGPoint; let accentMiddleOpacity: Double; let actionCenter: CGPoint }
    static func spec(_ mode: ThemeAppearance) -> Spec {
        mode == .light ? Spec(baseTarget: "#ffffff", accentCenter: CGPoint(x: 0.72, y: 0.22), accentMiddleOpacity: 0.72, actionCenter: CGPoint(x: 0.18, y: 0.82))
            : Spec(baseTarget: "#09090b", accentCenter: CGPoint(x: 0.28, y: 0.78), accentMiddleOpacity: 0.62, actionCenter: CGPoint(x: 0.82, y: 0.18))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        if image == nil || imageScale != scale { image = Self.render(colors: colors, mode: mode, scale: scale); imageScale = scale }
        // The view is 4pt larger than the ball so the ball's 1px/2px shadow is not clipped.
        let s = min(bounds.width, bounds.height) - 4
        let ball = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        // The edge shadow: `0 1px 2px` (outer) under the ball.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = NSColor.black.withAlphaComponent(mode == .dark ? 0.18 : 0.08)
        shadow.set()
        Themed.color(\.background).setFill()
        NSBezierPath(ovalIn: ball).fill()
        NSGraphicsContext.restoreGraphicsState()
        let inner = ball.insetBy(dx: 2, dy: 2)
        if let image {
            ctx.saveGState()
            ctx.addEllipse(in: inner)
            ctx.clip()
            ctx.translateBy(x: inner.minX, y: inner.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: inner.size))
            ctx.restoreGState()
        }
    }

    /// The 52px padding box: base color, two radial gradients interpolated in OKLab, blurred 3px, scaled 1.1.
    static func render(colors: [ThemeColorRole: String], mode: ThemeAppearance, scale: CGFloat) -> CGImage? {
        let spec = spec(mode)
        let side = 52.0, px = Int((side * scale).rounded())
        func color(_ role: ThemeColorRole) -> ThemeCSSColor { ThemeCSSColor.parse(colors[role] ?? "") ?? .transparent }
        let base = ThemeCSSColor.mix(.oklab, color(.canvas), 80, ThemeCSSColor.parse(spec.baseTarget)!, nil)
        let accent = color(.accent), action = color(.messageAction)
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        // Drawn with a margin so the blur has real pixels to spread from the edge.
        let margin = Int(12 * scale), full = px + 2 * margin
        guard let ctx = CGContext(data: nil, width: full, height: full, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(full) / 2, y: CGFloat(full) / 2)
        ctx.scaleBy(x: 1.1 * scale, y: -1.1 * scale)
        ctx.translateBy(x: -side / 2, y: -side / 2)
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        // The scaled element's own box is all the gradient paints; past it the layer is transparent.
        ctx.saveGState()
        ctx.addEllipse(in: box)
        ctx.clip()
        ctx.setFillColor(base.nsColor.cgColor)
        ctx.fill(box)
        func radial(_ center: CGPoint, _ stops: [(Double, ThemeCSSColor)]) {
            let c = CGPoint(x: center.x * side, y: center.y * side)
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: side, y: 0), CGPoint(x: 0, y: side), CGPoint(x: side, y: side)]
            let radius = corners.map { hypot($0.x - c.x, $0.y - c.y) }.max()!
            var locations: [CGFloat] = [], cgColors: [CGColor] = []
            // OKLab interpolation sampled between the CSS stops.
            for i in 0..<(stops.count - 1) {
                let (p0, c0) = stops[i], (p1, c1) = stops[i + 1]
                for k in 0..<12 {
                    let t = Double(k) / 12
                    locations.append(CGFloat(p0 + (p1 - p0) * t))
                    cgColors.append(ThemeCSSColor.mix(.oklab, c0, (1 - t) * 100, c1, t * 100).nsColor.cgColor)
                }
            }
            locations.append(CGFloat(stops.last!.0))
            cgColors.append(stops.last!.1.nsColor.cgColor)
            guard let g = CGGradient(colorsSpace: space, colors: cgColors as CFArray, locations: locations) else { return }
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
        }
        func faded(_ c: ThemeCSSColor, _ a: Double) -> ThemeCSSColor { var x = c; x.alpha *= a; return x }
        var clear = accent; clear.alpha = 0
        radial(spec.accentCenter, [(0, accent), (0.28, faded(accent, spec.accentMiddleOpacity)), (0.58, clear)])
        var actionClear = action; actionClear.alpha = 0
        radial(spec.actionCenter, [(0, faded(action, 0.45)), (0.55, actionClear)])
        ctx.restoreGState()
        guard let sharp = ctx.makeImage() else { return nil }
        // `filter: blur(3px)`: a Gaussian with a 3px standard deviation.
        let input = CIImage(cgImage: sharp)
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3 * scale])
            .cropped(to: input.extent)
        let ci = CIContext(options: [.workingColorSpace: space])
        let crop = CGRect(x: margin, y: margin, width: px, height: px)
        return ci.createCGImage(blurred, from: crop, format: .RGBA8, colorSpace: space)
    }
}

/// One circle of a card (ThemePreviewCircles.tsx:182-227): a 68px round button, `p-1`, `hover:scale-105` unless
/// picked; picked adds an inset 2px ring and a sun or moon badge.
final class ThemeCircleButton: ControlView {
    let ball = ThemePreviewCircleView()
    var isPicked = false { didSet { restyle(); setAccessibilityValue(isPicked) } }
    private let ring = ThemeCircleRingView()
    private let badge: ThemeCircleBadgeView
    let mode: ThemeAppearance

    init(mode: ThemeAppearance, colors: [ThemeColorRole: String], label: String) {
        self.mode = mode
        badge = ThemeCircleBadgeView(icon: mode == .light ? .sun : .moon)
        super.init(frame: NSRect(x: 0, y: 0, width: 68, height: 68))
        scalesWhenPressed = false
        ball.mode = mode
        ball.colors = colors
        addSubview(ball)
        addSubview(ring)
        addSubview(badge)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Use \(label) \(mode.rawValue) mode")
        TooltipController.attach(to: self, text: mode == .light ? "Use for light mode only" : "Use for dark mode only")
        restyle()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 68, height: 68) }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }

    private func restyle() {
        ring.isHidden = !isPicked
        badge.isHidden = !isPicked
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // `hover:scale-105` (not when picked), around the center.
        let s: CGFloat = state.hovered && !isPicked ? 1.05 : 1
        ball.frame = NSRect(x: bounds.midX - 28 * s - 2, y: bounds.midY - 28 * s - 2, width: 56 * s + 4, height: 56 * s + 4)
        ring.frame = bounds
        // `bottom-0.5 right-0.5 size-5`.
        badge.frame = NSRect(x: bounds.width - 2 - 20, y: bounds.height - 2 - 20, width: 20, height: 20)
    }
}

/// The picked circle's `inset 0 0 0 2px var(--ring)`.
final class ThemeCircleRingView: DSView {
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        Themed.color(\.ring).setStroke()
        let p = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        p.lineWidth = 2
        p.stroke()
    }
}

/// The picked circle's badge: `size-5 rounded-full border border-border/70 bg-background shadow-sm` with a
/// `size-3` sun or moon.
final class ThemeCircleBadgeView: DSView {
    private let icon: IconView
    init(icon name: IconName) {
        icon = IconView(name: name, size: 12, strokeColor: Themed.color(\.foreground))
        super.init(frame: .zero)
        addSubview(icon)
    }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.05)
        shadow.set()
        Themed.color(\.background).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        NSGraphicsContext.restoreGraphicsState()
        Themed.color(\.border, 0.7).setStroke()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12)
    }
}

/// `ThemeLibraryCard` (ThemeSettings.tsx:101-419) without collection variants: the circles, the title and the
/// card's icon buttons. The card surface click uses the theme.
final class ThemeLibraryCardView: ControlView {
    struct Actions {
        var use: @MainActor @Sendable () -> Void
        var useMode: @MainActor @Sendable (ThemeAppearance) -> Void
        var duplicate: (@MainActor @Sendable () -> Void)?
        var edit: (@MainActor @Sendable () -> Void)?
        var export: (@MainActor @Sendable () -> Void)?
        var remove: (@MainActor @Sendable () -> Void)?
    }

    let card: ThemeCardDefinition
    private let decoration = BoxDecorationLayer()
    private(set) var circles: [ThemeCircleButton] = []
    private let titleButton = ThemeCardTitleButton()
    private(set) var buttons: [ButtonView] = []

    init(card: ThemeCardDefinition, picked: [ThemeAppearance], actions: Actions) {
        self.card = card
        super.init(frame: .zero)
        scalesWhenPressed = false
        transitions = .colors // ThemeSettings.tsx:157
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        for preview in card.previews {
            let c = ThemeCircleButton(mode: preview.mode, colors: preview.colors, label: card.label)
            c.isPicked = picked.contains(preview.mode)
            c.action = { actions.useMode(preview.mode) }
            circles.append(c)
            addSubview(c)
        }
        titleButton.text = card.label
        titleButton.action = actions.use
        titleButton.setAccessibilityLabel("Use \(card.label) theme")
        addSubview(titleButton)
        func icon(_ name: IconName, _ label: String, _ tip: String, _ run: (@MainActor @Sendable () -> Void)?, _ variant: ButtonView.Variant = .ghost) {
            guard let run else { return }
            let b = ButtonView(nil, icon: name, variant: variant, size: .iconXs)
            b.setAccessibilityLabel("\(label) \(card.label)")
            b.action = run
            TooltipController.attach(to: b, text: tip)
            buttons.append(b)
            addSubview(b)
        }
        icon(.copy, "Duplicate", "Duplicate theme", actions.duplicate)
        icon(.penLine, "Edit", "Edit theme", actions.edit)
        icon(.upload, "Export", "Export theme file", actions.export)
        icon(.trash2, "Remove", "Remove theme", actions.remove, .ghostDestructive)
        action = actions.use
        TooltipController.attach(to: self, text: card.previews.count > 1 ? "Use for both light and dark" : "Use for \(card.previews[0].mode.rawValue) mode only")
        setAccessibilityRole(.group)
        setAccessibilityLabel(card.label)
        restyle()
    }

    static let height: CGFloat = 1 + 12 + 68 + 8 + 24 + 12 + 1

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 12
        box.border = Themed.color(\.border, 0.7)
        box.fill = state.hovered ? Themed.color(\.accent, 0.1) : Themed.color(\.card, 0.6)
        decoration.boxStyle = box
    }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let total = CGFloat(circles.count) * 68 + CGFloat(max(0, circles.count - 1)) * 10
        var x = (bounds.width - total) / 2
        for c in circles {
            c.frame = NSRect(x: x, y: 1 + 12, width: 68, height: 68)
            x += 78
        }
        // Footer: `px-3 pb-3 pt-2`, buttons `gap-1` at the end.
        let rowY: CGFloat = 1 + 12 + 68 + 8
        var bx = bounds.width - 1 - 12
        for b in buttons.reversed() {
            bx -= 24
            b.frame = NSRect(x: bx, y: rowY, width: 24, height: 24)
            bx -= 4
        }
        let titleMax = (buttons.isEmpty ? bounds.width - 1 - 12 : bx + 4 - 8) - 13
        titleButton.frame = NSRect(x: 13, y: rowY + 2, width: min(titleMax, titleButton.intrinsicContentSize.width), height: 20)
    }
}

/// The card title (`min-w-0 truncate text-sm font-medium text-foreground`), a button.
final class ThemeCardTitleButton: ControlView {
    private let label = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    var text: String { get { label.text } set { label.text = newValue; invalidateIntrinsicContentSize() } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 20
        addSubview(label)
        setAccessibilityRole(.button)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1, height: 20) }
    override func layout() { super.layout(); label.frame = bounds }
}

/// The card grid (`grid gap-2`, `repeat(auto-fit, minmax(min(100%, 16rem), 1fr))`).
final class ThemeCardGridView: DSView, SettingsGroupRow {
    var cards: [ThemeLibraryCardView] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; cards.forEach(addSubview); needsLayout = true }
    }

    static func columns(_ width: CGFloat) -> Int { max(1, Int((width + 8) / (256 + 8))) }

    func height(forWidth width: CGFloat) -> CGFloat {
        let rows = (cards.count + Self.columns(width) - 1) / Self.columns(width)
        return rows == 0 ? 0 : CGFloat(rows) * ThemeLibraryCardView.height + CGFloat(rows - 1) * 8
    }

    override func layout() {
        super.layout()
        let n = Self.columns(bounds.width)
        let w = (bounds.width - CGFloat(n - 1) * 8) / CGFloat(n)
        for (i, c) in cards.enumerated() {
            c.frame = NSRect(x: CGFloat(i % n) * (w + 8), y: CGFloat(i / n) * (ThemeLibraryCardView.height + 8), width: w, height: ThemeLibraryCardView.height)
        }
    }
}

/// The Theme heading's buttons (`flex flex-wrap items-center justify-end gap-2`).
final class ThemeHeaderButtonsView: DSView {
    let create = ButtonView("Create theme", icon: .paintbrush, variant: .outline, size: .xs)
    let add = ButtonView("Add theme", icon: .plus, variant: .outline, size: .xs)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(create)
        addSubview(add)
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: create.intrinsicContentSize.width + 8 + add.intrinsicContentSize.width, height: 24)
    }
    override func layout() {
        super.layout()
        let c = create.intrinsicContentSize, a = add.intrinsicContentSize
        create.frame = NSRect(x: 0, y: 0, width: c.width, height: 24)
        add.frame = NSRect(x: c.width + 8, y: 0, width: a.width, height: 24)
    }
}
