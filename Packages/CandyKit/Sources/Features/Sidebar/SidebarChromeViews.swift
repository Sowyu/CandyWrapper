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

/// `.sidebar-stage-backdrop` (index.css:498-518): 80px tall, masked to fade out from 55% to 92%, with
/// the `--sidebar-stage-fade` overlay. Drawn once per size and appearance.
/// CandyWrapper's own art replaces T3's `NightlySkyArt` here: the teddy-and-milk corner of "Candy Town"
/// by Aya_Lu (pixabay.com/illustrations/candy-town-city-buildings-8579300, Pixabay Content License)
/// as a duotone, placed like CSS `background-size: 122%; background-position: 97% 95%`.
// ponytail: Dev blueprint art is not drawn; port DevBlueprintArt if dev builds need it
final class StageBackdropView: DSView {
    override var wantsUpdateLayer: Bool { false }
    /// The send button (T3's `StageBackdropButtonArt` slot): the teddy circle, no fade or mask.
    var compact = false { didSet { needsDisplay = true } }

    /// Title and toggle color over the art: white in both appearances.
    static func ink(_ alpha: CGFloat = 1) -> NSColor { .white.withAlphaComponent(alpha) }
    /// The duotone ends: luma 0 paints `shadow`, luma 255 paints `light`.
    static let candyShadow = NSColor(name: nil) { $0.isDark ? srgb(0x170a26) : srgb(0x22103a) }
    static let candyLight = NSColor(name: nil) { $0.isDark ? srgb(0xa45e8c) : srgb(0xdc8fbd) }
    static func srgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// What scripts/gen-candy-art.swift keeps of the 1280x905 source, top-left origin: the band shows
    /// x 17.5% to 99.5% at any width and y 53% to 97% at the narrowest sidebar (208pt).
    static let candySource = CGSize(width: 1280, height: 905)
    static let candyCrop = CGRect(x: 223, y: 440, width: 1057, height: 465)
    /// The send button's circle in source pixels: the teddy with both ears in, its face above the arrow.
    static let teddy = CGRect(x: 940, y: 606, width: 196, height: 196)
    /// 8-bit luma (Rec. 709 on sRGB), mapped from the bundle: its pages stay clean, so they don't
    /// count against the app's memory, and there is nothing to decode.
    static let candyLuma: CGImage? = {
        let w = Int(candyCrop.width), h = Int(candyCrop.height)
        guard let url = Bundle.module.url(forResource: "candy-town", withExtension: "gray"),
              let data = try? NSData(contentsOf: url, options: .alwaysMapped), data.length == w * h,
              let provider = CGDataProvider(data: data)
        else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The art's placement runs past the view. Unclipped, AppKit sized the backing store to hold
        // that drawing too, up to the whole window (27 MB at 2x).
        clipsToBounds = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        // Explicit bounds: under AppKit's recorded drawing an unbounded group got a window-sized
        // scratch layer (27 MB at 2x).
        ctx.beginTransparencyLayer(in: bounds, auxiliaryInfo: nil)
        drawCandyTown(ctx)
        if !compact { drawFadeAndMask(ctx) }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The duotone: the shadow color everywhere, then the light color through the luma as a mask.
    private func drawCandyTown(_ ctx: CGContext) {
        let w = bounds.width, h = bounds.height
        ctx.setFillColor(Self.candyShadow.cgColor(in: self))
        ctx.fill(bounds)
        guard let luma = Self.candyLuma else { return }
        // Where the whole source lands: the teddy circle fills the button; the band is CSS
        // `background-size: 122%; background-position: 97% 95%`.
        let scale: CGFloat, origin: CGPoint
        if compact {
            scale = w / Self.teddy.width
            origin = CGPoint(x: -Self.teddy.minX * scale, y: -Self.teddy.minY * scale)
        } else {
            scale = 1.22 * w / Self.candySource.width
            origin = CGPoint(x: (w - Self.candySource.width * scale) * 0.97, y: (h - Self.candySource.height * scale) * 0.95)
        }
        let crop = Self.candyCrop
        let rect = CGRect(x: origin.x + crop.minX * scale, y: origin.y + crop.minY * scale,
                          width: crop.width * scale, height: crop.height * scale)
        ctx.saveGState()
        // The view is flipped; flip the rect back so the image's first row lands at its top.
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.clip(to: rect, mask: luma)
        ctx.setFillColor(Self.candyLight.cgColor(in: self))
        ctx.fill(rect)
        ctx.restoreGState()
    }

    private func drawFadeAndMask(_ ctx: CGContext) {
        let h = bounds.height, space = CGColorSpaceCreateDeviceRGB()
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
    }
}

/// `SidebarBrandMark` (SidebarChrome.tsx:126-142): the T3 wordmark at cap height, `gap-1`, then "Code"
/// in muted text, `text-sm font-medium tracking-tight`. Over the stage art T3 uses white and white/70;
/// over the candy art the colors are `StageBackdropView.ink`.
final class SidebarBrandView: DSView {
    var onBackdrop = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }

    static let wordmark: CGPath = {
        // T3Wordmark.tsx, viewBox 15.5309 37 94.3941 56.96.
        let d = "M33.4509 93V47.56H15.5309V37H64.3309V47.56H46.4109V93H33.4509ZM86.7253 93.96C82.832 93.96 78.9653 93.4533 75.1253 92.44C71.2853 91.3733 68.032 89.88 65.3653 87.96L70.4053 78.04C72.5386 79.5867 75.0186 80.8133 77.8453 81.72C80.672 82.6267 83.5253 83.08 86.4053 83.08C89.6586 83.08 92.2186 82.44 94.0853 81.16C95.952 79.88 96.8853 78.12 96.8853 75.88C96.8853 73.7467 96.0586 72.0667 94.4053 70.84C92.752 69.6133 90.0853 69 86.4053 69H80.4853V60.44L96.0853 42.76L97.5253 47.4H68.1653V37H107.365V45.4L91.8453 63.08L85.2853 59.32H89.0453C95.9253 59.32 101.125 60.8667 104.645 63.96C108.165 67.0533 109.925 71.0267 109.925 75.88C109.925 79.0267 109.099 81.9867 107.445 84.76C105.792 87.48 103.259 89.6933 99.8453 91.4C96.432 93.1067 92.0586 93.96 86.7253 93.96Z"
        return SimplePath.parse(d)
    }()

    static var font: NSFont { DSFont.ui(14, weight: .medium) }
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
        let fg = onBackdrop ? StageBackdropView.ink() : SB.c(\.foreground)
        let muted = onBackdrop ? StageBackdropView.ink(0.7) : SB.c(\.mutedForeground)
        if onBackdrop {
            // The white title lifts off the candy art: `text-shadow: 0 1px 2px rgb(20 6 30 / 35%)`.
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: CGColor(srgbRed: 20 / 255, green: 6 / 255, blue: 30 / 255, alpha: 0.35))
        }
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
    /// "Clear thread search" (SidebarThreadHeader.tsx:110-123): `icon-micro ghost-muted`, a `size-3` x, while searching.
    let clearButton = ButtonView(nil, icon: .x, variant: .ghostMuted, size: .iconMicro)
    var onChange: (@MainActor (String) -> Void)?
    /// Field editor commands (moveDown:, moveUp:, insertNewline:, cancelOperation:). True when handled.
    var onCommand: (@MainActor (Selector) -> Bool)?

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue; syncClear() }
    }

    private func syncClear() {
        let searching = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if clearButton.isHidden == searching { clearButton.isHidden = !searching; needsLayout = true }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        onCommand?(commandSelector) ?? false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clearButton.iconSize = 12
        clearButton.setAccessibilityLabel("Clear thread search")
        clearButton.isHidden = true
        clearButton.action = { [weak self] in
            guard let self else { return }
            self.text = ""
            self.onChange?("")
            self.window?.makeFirstResponder(self.field)
        }
        addSubview(clearButton)
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
    func controlTextDidChange(_ obj: Notification) { syncClear(); onChange?(field.stringValue) }

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
        // `gap-2`, then the 20pt clear button before the `px-2` edge.
        let clear: CGFloat = clearButton.isHidden ? 0 : 20 + 8
        field.frame = NSRect(x: 30, y: (bounds.height - fh) / 2, width: max(0, bounds.width - 38 - clear), height: fh)
        clearButton.frame = NSRect(x: bounds.width - 8 - 20, y: (bounds.height - 20) / 2, width: 20, height: 20)
    }
}
