import AppKit
import CoreText
import DesignSystem

/// `resolveSidebarStageBackdropVariant` (SidebarStageBackdrop.tsx:15-24): Nightly and Dev builds get header art.
public enum SidebarStage: Sendable {
    case none, nightly, dev

    /// `resolveServerBackedAppStageLabel` (branding.logic.ts): a nightly or preview server version means Nightly.
    public static func from(serverVersion: String?, fallbackLabel: String = "Alpha") -> SidebarStage {
        let label: String
        if let v = serverVersion, v.range(of: #"^[^-+]+-(?:nightly|preview)\.\d{8}\.\d+$"#, options: .regularExpression) != nil {
            label = "Nightly"
        } else {
            label = fallbackLabel
        }
        switch label.lowercased() {
        case "nightly": return .nightly
        case "dev": return .dev
        default: return .none
        }
    }
}

/// `NightlySkyArt` (SidebarStageBackdrop.tsx:98-200) under `.sidebar-stage-backdrop` (index.css:498-518):
/// 80px tall, viewBox height 96 sliced from the left, masked to fade out from 55% to 92%, with the
/// `--sidebar-stage-fade` overlay. Drawn once per size and appearance.
// ponytail: Dev blueprint art is not drawn; port DevBlueprintArt if dev builds need it
final class StageBackdropView: DSView {
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The blur draws its shapes off to the side. Unclipped, AppKit sized the backing store to
        // hold that drawing too, up to the whole window (27 MB at 2x).
        clipsToBounds = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (14, 10, 0.6, 0.85), (38, 22, 0.4, 0.55), (58, 8, 0.5, 0.7), (84, 16, 0.4, 0.5), (104, 7, 0.6, 0.8),
        (126, 20, 0.4, 0.55), (148, 11, 0.5, 0.7), (170, 24, 0.4, 0.5), (192, 9, 0.6, 0.8), (214, 18, 0.4, 0.55),
        (236, 8, 0.5, 0.7), (258, 20, 0.45, 0.6), (278, 11, 0.55, 0.75), (26, 34, 0.4, 0.45), (118, 34, 0.4, 0.45),
        (202, 32, 0.4, 0.5), (268, 34, 0.4, 0.45)]
    static let sparkles: [(CGFloat, CGFloat)] = [(70, 28), (160, 36), (246, 26)]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        func col(_ k: KeyPath<Palette, TokenColor>, _ a: CGFloat = 1) -> CGColor {
            let c = SB.c(k).cgColor(in: self)
            return c.copy(alpha: c.alpha * a) ?? c
        }
        let w = bounds.width, h = bounds.height
        let s = h / 96 // xMinYMin slice: height decides the scale for any sidebar width
        ctx.saveGState()
        // Explicit bounds: under AppKit's recorded drawing an unbounded group got a window-sized
        // scratch layer (27 MB at 2x).
        ctx.beginTransparencyLayer(in: bounds, auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        let unitsW = w / s
        // The star tiles below are whole 288-unit tiles; without this the last one spills past
        // the sidebar wherever the context isn't clipped to the view (layer.render(in:)).
        ctx.clip(to: CGRect(x: 0, y: 0, width: unitsW, height: 96))
        let space = CGColorSpaceCreateDeviceRGB()
        // Sky: linear (24,0) to (264,96), spread reflect.
        // spreadMethod reflect: one long gradient whose segments alternate direction, no seams.
        let dx: CGFloat = 240, dy: CGFloat = 96
        let len2 = dx * dx + dy * dy
        let segments = Int((unitsW * dx + 96 * dy) / len2) + 3
        var colors: [CGColor] = [], locations: [CGFloat] = []
        let base = [col(\.stageNightBottom), col(\.stageNightMid), col(\.stageNightTop)]
        for k in 0..<(segments + 1) {
            let seg = k % 2 == 1 ? base : base.reversed() // segment 0 is the mirror before (24,0)
            for (j, c) in seg.enumerated() {
                colors.append(c)
                locations.append((CGFloat(k) + CGFloat(j) / 2) / CGFloat(segments + 1))
            }
        }
        let sky = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: unitsW, height: 96))
        let start = CGPoint(x: 24 - dx, y: -dy)
        ctx.drawLinearGradient(sky, start: start,
                               end: CGPoint(x: start.x + dx * CGFloat(segments + 1), y: start.y + dy * CGFloat(segments + 1)),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        // Glow: radial at (216,18) rotated 137deg, scale (120,84), tiled every 640 units.
        let glow = CGGradient(colorsSpace: space, colors: [col(\.stageNightGlowHighlight, 0.4), col(\.stageNightGlowSecondary, 0.16),
                                                            col(\.stageNightBottom, 0)] as CFArray, locations: [0, 0.5, 1])!
        var tileX: CGFloat = 0
        while tileX < unitsW {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: tileX, y: 0, width: 640, height: 96))
            ctx.translateBy(x: tileX + 216, y: 18)
            ctx.rotate(by: 137 * .pi / 180)
            ctx.scaleBy(x: 120, y: 84)
            ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            ctx.restoreGState()
            tileX += 640
        }
        // Stars and sparkles, tiled every 288 units.
        tileX = 0
        while tileX < unitsW {
            for (cx, cy, r, o) in Self.stars {
                ctx.setFillColor(col(\.stageNightLine, o))
                ctx.fillEllipse(in: CGRect(x: tileX + cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            ctx.setStrokeColor(col(\.stageNightSparkle, 0.7))
            ctx.setLineWidth(0.6)
            ctx.setLineCap(.round)
            for (x, y) in Self.sparkles {
                ctx.move(to: CGPoint(x: tileX + x - 1.5, y: y)); ctx.addLine(to: CGPoint(x: tileX + x + 1.5, y: y))
                ctx.move(to: CGPoint(x: tileX + x, y: y - 1.5)); ctx.addLine(to: CGPoint(x: tileX + x, y: y + 1.5))
            }
            ctx.strokePath()
            tileX += 288
        }
        // Clouds: blurred (stdDeviation 4) shapes filled with a horizontal gradient.
        for (path, alpha) in [(Self.cloudA, CGFloat(1)), (Self.cloudB, 0.8)] {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            // ponytail: the blur paints one flat color (the cloud gradient's middle stop); blur a bitmap if the gradient shows
            drawBlurred(ctx, path, sigma: 4 * s, scale: s, color: col(\.stageNightSecondary, 0.62))
            ctx.restoreGState()
        }
        ctx.restoreGState()
        // ::after fade to --sidebar-stage-fade.
        let fade = SB.c(\.sidebarStageFade).cgColor(in: self)
        let stops: [(CGFloat, CGFloat)] = [(0, 0), (0.28, 0), (0.40, 0.1), (0.52, 0.3), (0.64, 0.58), (0.75, 0.82), (0.85, 0.96), (0.93, 1)]
        let fadeGradient = CGGradient(colorsSpace: space, colors: stops.map { fade.copy(alpha: fade.alpha * $0.1)! } as CFArray,
                                      locations: stops.map(\.0))!
        ctx.drawLinearGradient(fadeGradient, start: .zero, end: CGPoint(x: 0, y: h), options: [.drawsAfterEndLocation])
        // mask-image: black 0-55%, transparent at 92%.
        ctx.setBlendMode(.destinationIn)
        let mask = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
                              locations: [0, 0.55, 0.92])!
        ctx.drawLinearGradient(mask, start: .zero, end: CGPoint(x: 0, y: h), options: [.drawsAfterEndLocation])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Gaussian blur by drawing far off-canvas and letting the shadow land in place.
    private func drawBlurred(_ ctx: CGContext, _ path: CGPath, sigma: CGFloat, scale: CGFloat, color: CGColor) {
        // Just past the clouds (x up to about 300 units) plus 3 sigma.
        let shift: CGFloat = 320
        // Shadow offsets are in device space; this view is flipped, so +y in user space is -y in device space.
        // Shadow offsets and blur are in the base space (points), outside the CTM.
        ctx.setShadow(offset: CGSize(width: shift * scale, height: 0), blur: sigma * 2, color: color)
        // The group only needs to hold the shifted shape; unbounded, its scratch layer spanned the
        // whole shift and the view (tens of MB at 2x).
        let margin = 3 * sigma / scale
        ctx.beginTransparencyLayer(in: path.boundingBox.offsetBy(dx: -shift, dy: 0).insetBy(dx: -margin, dy: -margin),
                                   auxiliaryInfo: nil)
        ctx.translateBy(x: -shift, y: 0)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.endTransparencyLayer()
    }

    static let cloudA: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -12, y: 88))
        p.addCurve(to: CGPoint(x: 14, y: 63), control1: CGPoint(x: -12, y: 74), control2: CGPoint(x: 0, y: 63))
        p.addCurve(to: CGPoint(x: 44, y: 41), control1: CGPoint(x: 18, y: 50), control2: CGPoint(x: 30, y: 41))
        p.addCurve(to: CGPoint(x: 74, y: 62), control1: CGPoint(x: 58, y: 41), control2: CGPoint(x: 70, y: 49))
        p.addCurve(to: CGPoint(x: 94, y: 54), control1: CGPoint(x: 79, y: 57), control2: CGPoint(x: 86, y: 54))
        p.addCurve(to: CGPoint(x: 124, y: 82), control1: CGPoint(x: 110, y: 54), control2: CGPoint(x: 123, y: 66))
        p.addCurve(to: CGPoint(x: 141, y: 96), control1: CGPoint(x: 132, y: 83), control2: CGPoint(x: 138, y: 88))
        p.addLine(to: CGPoint(x: -12, y: 96))
        p.closeSubpath()
        return p
    }()

    static let cloudB: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 150, y: 96))
        p.addCurve(to: CGPoint(x: 173, y: 75), control1: CGPoint(x: 151, y: 84), control2: CGPoint(x: 161, y: 75))
        p.addCurve(to: CGPoint(x: 198, y: 57), control1: CGPoint(x: 176, y: 64), control2: CGPoint(x: 186, y: 57))
        p.addCurve(to: CGPoint(x: 223, y: 75), control1: CGPoint(x: 210, y: 57), control2: CGPoint(x: 220, y: 64))
        p.addCurve(to: CGPoint(x: 241, y: 87), control1: CGPoint(x: 231, y: 75), control2: CGPoint(x: 238, y: 80))
        p.addCurve(to: CGPoint(x: 260, y: 96), control1: CGPoint(x: 250, y: 87), control2: CGPoint(x: 257, y: 91))
        p.closeSubpath()
        return p
    }()
}

/// `SidebarBrandMark` (SidebarChrome.tsx:126-142): the T3 wordmark at cap height, `gap-1`, then "Code"
/// in muted text, `text-sm font-medium tracking-tight`. White and white/70 over the stage art.
final class SidebarBrandView: DSView {
    var onBackdrop = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }

    static let wordmark: CGPath = {
        // T3Wordmark.tsx, viewBox 15.5309 37 94.3941 56.96.
        let d = "M33.4509 93V47.56H15.5309V37H64.3309V47.56H46.4109V93H33.4509ZM86.7253 93.96C82.832 93.96 78.9653 93.4533 75.1253 92.44C71.2853 91.3733 68.032 89.88 65.3653 87.96L70.4053 78.04C72.5386 79.5867 75.0186 80.8133 77.8453 81.72C80.672 82.6267 83.5253 83.08 86.4053 83.08C89.6586 83.08 92.2186 82.44 94.0853 81.16C95.952 79.88 96.8853 78.12 96.8853 75.88C96.8853 73.7467 96.0586 72.0667 94.4053 70.84C92.752 69.6133 90.0853 69 86.4053 69H80.4853V60.44L96.0853 42.76L97.5253 47.4H68.1653V37H107.365V45.4L91.8453 63.08L85.2853 59.32H89.0453C95.9253 59.32 101.125 60.8667 104.645 63.96C108.165 67.0533 109.925 71.0267 109.925 75.88C109.925 79.0267 109.099 81.9867 107.445 84.76C105.792 87.48 103.259 89.6933 99.8453 91.4C96.432 93.1067 92.0586 93.96 86.7253 93.96Z"
        return SimplePath.parse(d)
    }()

    static let font = DSFont.ui(14, weight: .medium)
    /// `tracking-tight`: -0.025em.
    static let tracking: CGFloat = -0.35

    var markWidth: CGFloat { Self.font.capHeight * 94.3941 / 56.96 }
    var codeLine: CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: "Code", attributes: [.font: Self.font, .kern: Self.tracking]))
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(markWidth + 4 + CGFloat(CTLineGetTypographicBounds(codeLine, nil, nil, nil))), height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cap = Self.font.capHeight
        // `items-baseline` in a 28px box with the 20px line centred: baseline as for the text line.
        let baseline = TextLine(NSAttributedString(string: "Code", attributes: [.font: Self.font])).baseline(top: 4, lineHeight: 20)
        let fg = onBackdrop ? NSColor.white : SB.c(\.foreground)
        let muted = onBackdrop ? NSColor.white.withAlphaComponent(0.7) : SB.c(\.mutedForeground)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: baseline - cap)
        let s = cap / 56.96
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -15.5309, y: -37)
        ctx.addPath(Self.wordmark)
        ctx.setFillColor(fg.cgColor(in: self))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShouldSmoothFonts(true)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Code", attributes: [
            .font: Self.font, .kern: Self.tracking, .foregroundColor: muted]))
        ctx.textMatrix = .identity
        ctx.translateBy(x: markWidth + 4, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// Minimal SVG path parser for the absolute M, L, H, V, C, Z commands the wordmark uses.
enum SimplePath {
    static func parse(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var tokens: [String] = []
        var current = ""
        for ch in d {
            if ch.isLetter { if !current.isEmpty { tokens.append(current) }; tokens.append(String(ch)); current = "" }
            else if ch == " " || ch == "," { if !current.isEmpty { tokens.append(current) }; current = "" }
            else if ch == "-", !current.isEmpty, current.last != "e" { tokens.append(current); current = "-" }
            else { current.append(ch) }
        }
        if !current.isEmpty { tokens.append(current) }
        var i = 0, cmd = "M", pt = CGPoint.zero
        func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter { cmd = tokens[i]; i += 1; if cmd == "Z" { p.closeSubpath(); continue } }
            switch cmd {
            case "M": pt = CGPoint(x: num(), y: num()); p.move(to: pt); cmd = "L"
            case "L": pt = CGPoint(x: num(), y: num()); p.addLine(to: pt)
            case "H": pt.x = num(); p.addLine(to: pt)
            case "V": pt.y = num(); p.addLine(to: pt)
            case "C":
                let c1 = CGPoint(x: num(), y: num()), c2 = CGPoint(x: num(), y: num())
                pt = CGPoint(x: num(), y: num())
                p.addCurve(to: pt, control1: c1, control2: c2)
            default: i += 1
            }
        }
        return p
    }
}

/// The header group's search field (SidebarThreadHeader.tsx): `h-8 px-2 py-1.5 gap-2 rounded-md`, a search
/// glyph in `--sidebar-icon-color` and a 14px medium input with the "Search" placeholder.
final class SidebarSearchFieldView: DSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let icon = IconView(name: .search, size: 16)
    private let surface = CALayer()
    private var hovered = false { didSet { restyle() } }
    private var fieldHeight: CGFloat = 0
    var onChange: (@MainActor (String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.cornerRadius = 8
        surface.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(surface)
        addSubview(icon)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = SB.font(14, .medium)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel("Search threads")
        field.delegate = self
        addSubview(field)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        restyle()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.backgroundColor = hovered ? SB.c(\.sidebarRowHover).cgColor(in: self) : nil
        CATransaction.commit()
        icon.strokeColor = SB.c(\.sidebarIconColor)
        field.textColor = SB.c(\.sidebarForeground)
        field.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: SB.font(14, .medium), .foregroundColor: hovered ? SB.c(\.sidebarForeground) : SB.c(\.sidebarMutedForeground)])
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        // NSTextField adds 2pt of cell inset on the left; pull it back so text starts at 32.
        // Measured once: each intrinsicContentSize call kept about 47 KB of text layout alive.
        if fieldHeight == 0 { fieldHeight = ceil(field.intrinsicContentSize.height) }
        let fh = fieldHeight
        field.frame = NSRect(x: 30, y: (bounds.height - fh) / 2, width: bounds.width - 38, height: fh)
    }
}
