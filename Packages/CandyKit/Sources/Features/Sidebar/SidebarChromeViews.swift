import AppKit
import CoreImage
import CoreText
import DesignSystem

/// `resolveSidebarStageBackdropVariant` (SidebarStageBackdrop.tsx:15-24): Nightly and Dev builds get header art.
public enum SidebarStage: Sendable {
    case none, nightly, dev

    /// `resolveServerBackedAppStageLabel` (branding.logic.ts): a nightly or preview server version means Nightly.
    public static func from(serverVersion: String?, fallbackLabel: String = "Beta") -> SidebarStage {
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

/// CandyWrapper's softer take on `.sidebar-stage-backdrop` (index.css:498-518): a 112pt
/// wash that fades directly into the sidebar. Drawn once per size and appearance.
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
        if !compact { drawFadeMask(ctx) }
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
            origin = CGPoint(x: (w - Self.candySource.width * scale) * 0.97, y: (80 - Self.candySource.height * scale) * 0.95)
        }
        let crop = Self.candyCrop
        let rect = CGRect(x: origin.x + crop.minX * scale, y: origin.y + crop.minY * scale,
                          width: crop.width * scale, height: crop.height * scale)
        if !compact, let blurred = progressiveLuma(luma, at: rect, deviceScale: abs(ctx.convertToDeviceSpace(CGSize(width: 1, height: 1)).width)) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: bounds, mask: blurred)
            ctx.setFillColor(Self.candyLight.cgColor(in: self))
            ctx.fill(bounds)
            ctx.restoreGState()
            return
        }
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

    /// The band's progressive blur starts near the top and grows through the full wash,
    /// like a system variable blur. The duotone is linear in luma, so blurring the luma blurs the art.
    /// Baked once per device-pixel size; the luma has no colors, so both appearances share it.
    private var blurredLuma: (key: CGRect, image: CGImage)?
    static let blurRadius: CGFloat = 14
    private static let ci = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])

    private func progressiveLuma(_ luma: CGImage, at rect: CGRect, deviceScale s: CGFloat) -> CGImage? {
        let pw = Int((bounds.width * s).rounded()), ph = Int((bounds.height * s).rounded())
        guard pw > 0, ph > 0 else { return nil }
        let key = CGRect(x: rect.minX * s, y: rect.minY * s, width: CGFloat(pw), height: CGFloat(ph))
        if let blurredLuma, blurredLuma.key == key { return blurredLuma.image }
        guard let gray = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        gray.scaleBy(x: s, y: s)
        gray.interpolationQuality = .high
        gray.draw(luma, in: CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
        guard let placed = gray.makeImage() else { return nil }
        let extent = CGRect(x: 0, y: 0, width: pw, height: ph)
        // Core Image puts y = 0 at the bottom: sharp at 8% from the top, full blur at 90%.
        let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: CGFloat(ph) * 0.92), "inputColor0": CIColor.black,
            "inputPoint1": CIVector(x: 0, y: CGFloat(ph) * 0.10), "inputColor1": CIColor.white])?.outputImage
        let blur = CIFilter(name: "CIMaskedVariableBlur", parameters: [
            kCIInputImageKey: CIImage(cgImage: placed).clampedToExtent(), "inputMask": mask as Any,
            kCIInputRadiusKey: Self.blurRadius * s])
        guard let out = blur?.outputImage?.cropped(to: extent),
              let image = Self.ci.createCGImage(out, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        else { return nil }
        blurredLuma = (key, image)
        return image
    }

    private func drawFadeMask(_ ctx: CGContext) {
        // One smooth alpha fade keeps the candy's color as it dissolves into Glass. A dark
        // overlay followed by an alpha mask made a black stripe across the old header.
        let stops = (0...16).map { CGFloat($0) / 16 }
        let colors = stops.map { position -> CGColor in
            let t = min(1, max(0, (position - 0.12) / 0.88))
            let opacity = 1 - t * t * (3 - 2 * t)
            return CGColor(gray: 0, alpha: opacity)
        }
        ctx.setBlendMode(.destinationIn)
        let mask = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors as CFArray,
                              locations: stops)!
        ctx.drawLinearGradient(mask, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [.drawsAfterEndLocation])
    }
}

/// `SidebarBrand` (SidebarChrome.tsx:110-123): a link to "/" labelled "Go to threads", `h-7 rounded-md`
/// with `focus-visible:ring-2 ring-ring`. Inside it `SidebarBrandMark` (126-135): the mark at cap height,
/// `gap-1`, then the word in muted text, `text-sm font-medium tracking-tight`. CandyWrapper's candy glyph
/// and "Wrapper" stand in for T3's wordmark and "Code". Over the candy art the colors are `StageBackdropView.ink`.
final class SidebarBrandView: ControlView {
    var onBackdrop = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }
    static let word = "Wrapper"
    private let ring = BoxDecorationLayer()

    /// /tmp/cw-icon-final/glyph.svg (the app icon's white candy) cropped to its bounds, top-left at zero:
    /// the twisted ends and the body under `rotate(-30) scale(1.02)`, less the gloss stroke.
    static let glyph: CGPath = {
        let end: [[CGPoint]] = [[(-196, 0), (-336.5, -156), (-399.7, -50.8)], [(-196, 0), (-403.9, -29.2), (-403.9, 29.2)],
                                [(-196, 0), (-399.7, 50.8), (-336.5, 156)]].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }
        var parts = [CGPath(roundedRect: CGRect(x: -150, y: -125, width: 300, height: 250), cornerWidth: 125, cornerHeight: 125, transform: nil)]
        for var flip in [CGAffineTransform.identity, CGAffineTransform(scaleX: -1, y: 1)] {
            for tri in end {
                let p = CGMutablePath()
                p.addLines(between: tri, transform: flip)
                p.closeSubpath()
                parts.append(p)
            }
            parts.append(CGPath(roundedRect: CGRect(x: -208, y: -62, width: 44, height: 124), cornerWidth: 22, cornerHeight: 22, transform: &flip))
        }
        // `M -96 -40 A 92 80 0 0 1 -20 -92`: centre (-9.601, -12.513), angles -159.904 to -96.490 degrees.
        let gloss = CGMutablePath()
        let ellipse = CGAffineTransform(translationX: -9.601027, y: -12.512695).scaledBy(x: 92, y: 80)
        gloss.addArc(center: .zero, radius: 1, startAngle: -159.904172 * .pi / 180, endAngle: -96.490145 * .pi / 180,
                     clockwise: false, transform: ellipse)
        // One union, part by part: the mirrored ends wind the other way and would cancel under nonzero fill.
        let shape = parts.dropFirst().reduce(parts[0]) { $0.union($1) }.subtracting(gloss.copy(strokingWithWidth: 26, lineCap: .round, lineJoin: .miter, miterLimit: 10))
        var place = CGAffineTransform(rotationAngle: -.pi / 6).scaledBy(x: 1.02, y: 1.02)
        let box = shape.copy(using: &place)!.boundingBoxOfPath
        place = CGAffineTransform(translationX: -box.minX, y: -box.minY).rotated(by: -.pi / 6).scaledBy(x: 1.02, y: 1.02)
        return shape.copy(using: &place)!
    }()
    static let glyphSize = glyph.boundingBoxOfPath.size

    static var font: NSFont { DSFont.ui(14, weight: .medium) }
    /// `tracking-tight`: -0.025em.
    static let tracking: CGFloat = -0.35

    /// The candy stands taller than T3's cap-height wordmark (the user: "way bigger"), centred on the word.
    static let markHeight: CGFloat = 22
    static let gap: CGFloat = 6
    var markWidth: CGFloat { Self.markHeight * Self.glyphSize.width / Self.glyphSize.height }
    var wordLine: CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: Self.word, attributes: [.font: Self.font, .kern: Self.tracking]))
    }
    /// Dither shows the candy alone, like Capy's logo.
    var markOnly = false { didSet { if markOnly != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }

    override var intrinsicContentSize: NSSize {
        if markOnly { return NSSize(width: ceil(markWidth), height: 28) }
        return NSSize(width: ceil(markWidth + Self.gap + CGFloat(CTLineGetTypographicBounds(wordLine, nil, nil, nil))), height: 28)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scalesWhenPressed = false // a link, not a button
        setAccessibilityRole(.link)
        setAccessibilityLabel("Go to threads")
        ring.host = self
        layer?.addSublayer(ring)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.layout(boxSize: bounds.size)
        CATransaction.commit()
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        var box = BoxStyle()
        box.radius = 8
        if state.focusVisible { box.shadows = [BoxShadow(spread: 2, color: Themed.color(\.ring))] }
        ring.boxStyle = box
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ring.setNeedsDisplay()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cap = Self.font.capHeight
        // `items-baseline` in a 28px box with the 20px line centred: baseline as for the text line.
        let baseline = TextLine(NSAttributedString(string: Self.word, attributes: [.font: Self.font])).baseline(top: 4, lineHeight: 20)
        let fg = onBackdrop ? StageBackdropView.ink() : SB.c(\.foreground)
        let muted = onBackdrop ? StageBackdropView.ink(0.9) : SB.c(\.mutedForeground)
        if onBackdrop {
            // The white title lifts off the candy art: `text-shadow: 0 1px 2px rgb(20 6 30 / 35%)`.
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: CGColor(srgbRed: 20 / 255, green: 6 / 255, blue: 30 / 255, alpha: 0.35))
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: baseline - cap / 2 - Self.markHeight / 2)
        let s = Self.markHeight / Self.glyphSize.height
        ctx.scaleBy(x: s, y: s)
        ctx.addPath(Self.glyph)
        ctx.setFillColor(fg.cgColor(in: self))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        if markOnly { return }
        ctx.setShouldSmoothFonts(FontRuntime.smoothing)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: Self.word, attributes: [
            .font: Self.font, .kern: Self.tracking, .foregroundColor: muted]))
        ctx.textMatrix = .identity
        ctx.translateBy(x: markWidth + Self.gap, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// The header group's search field (SidebarThreadHeader.tsx): `h-8 px-2 py-1.5 gap-2 rounded-md`, a search
/// glyph in `--sidebar-icon-color` and a 14px medium input with the "Search" placeholder.
final class SidebarSearchFieldView: DSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let icon = IconView(name: .search, size: 16)
    private let surface = CALayer()
    private var hovered = false { didSet { restyle() } }
    private var editing = false { didSet { restyle() } }
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
    func controlTextDidBeginEditing(_ obj: Notification) { editing = true }
    func controlTextDidEndEditing(_ obj: Notification) { editing = false }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if WindowGlass.isActive(for: self) {
            surface.backgroundColor = hovered ? SB.c(\.sidebarRowHover).cgColor(in: self) : nil
            surface.borderWidth = editing ? 1 : 0
            surface.borderColor = editing ? SB.c(\.ring).withAlphaComponent(0.65).cgColor(in: self) : nil
            surface.cornerRadius = 10
        } else {
            surface.backgroundColor = hovered ? SB.c(\.sidebarRowHover).cgColor(in: self) : nil
            surface.borderWidth = 0
            surface.cornerRadius = 8
        }
        CATransaction.commit()
        icon.strokeColor = SB.c(\.sidebarIconColor)
        field.textColor = SB.c(\.sidebarForeground)
        // Dither: the nav rows' 13pt, so search reads as the first of them.
        let size: CGFloat = ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? 13 : 14
        if field.font?.pointSize != size { field.font = SB.font(size, .medium); fieldHeight = 0; needsLayout = true }
        field.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: SB.font(size, .medium), .foregroundColor: hovered ? SB.c(\.sidebarForeground) : SB.c(\.sidebarMutedForeground)])
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

/// Dither (after Capy's sidebar nav): a 28pt row with a 16pt line icon and a 13pt label, `rounded-md`, the row hover
/// fill on hover.
final class SidebarNavRowView: ControlView {
    static let height: CGFloat = 28
    private let icon: IconView
    private let label: LabelView

    init(_ name: IconName, _ text: String) {
        icon = IconView(name: name, size: 16)
        label = LabelView(text, font: SB.font(13, .medium), color: SB.c(\.foreground))
        super.init(frame: .zero)
        label.lineHeight = 20
        addSubview(icon)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 32, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 40), height: 20)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.cornerRadius = DitherChrome.controlRadius
        layer?.backgroundColor = state.hoverOrPressed ? SB.c(\.sidebarRowHover).cgColor(in: self) : nil
        icon.strokeColor = SB.c(\.sidebarMutedForeground)
    }
}


/// The account pill's avatar: the picture, or initials on a muted disc. A click opens Machines and connections, so a
/// hairline ring shows on hover.
final class SidebarAccountAvatarView: ControlView {
    static let size: CGFloat = 28
    /// The ring sits this far outside the picture.
    static let ringGap: CGFloat = 2
    let image = CALayer()
    let initials = LabelView("", font: SB.font(11, .semibold), color: SB.c(\.sidebarForeground))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        image.masksToBounds = true
        image.contentsGravity = .resizeAspectFill
        image.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(image)
        initials.alignment = .center
        initials.lineHeight = 16
        addSubview(initials)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Machines and connections")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let g = Self.ringGap, s = Self.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.frame = CGRect(x: g, y: g, width: s, height: s)
        image.cornerRadius = s / 2
        CATransaction.commit()
        initials.frame = NSRect(x: g, y: g + (s - 16) / 2, width: s, height: 16)
    }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.borderWidth = 1
        layer?.borderColor = SB.c(\.sidebarForeground, state.hoverOrPressed ? 0.35 : 0).cgColor(in: self)
        image.backgroundColor = SB.c(\.sidebarForeground, state.hoverOrPressed ? 0.18 : 0.12).cgColor(in: self)
    }
}

/// Dither (after Capy): the account row at the foot of the sidebar. A 28pt round avatar, the name, CandyWrapper's own
/// CPU and memory (`AppUsageReadoutView`), and a chevron. The avatar opens Settings at Machines and connections; the
/// rest opens the account menu above it: Settings, Usage and Appearance, then "Update all (N)" while updates wait. It
/// shows no e-mail, which was too easy to reveal on a screen share (the user, 2026-10-22).
/// The account pill's chevron: the only thing that opens the account menu, with its own hover fill.
final class SidebarAccountChevronButton: ControlView {
    static let size: CGFloat = 28
    let icon = IconView(name: .chevronUp, size: 16)
    /// The menu is open: the glyph turns down and keeps the pressed fill.
    var open = false { didSet { if open != oldValue { icon.setRotation(open ? 180 : 0); needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        addSubview(icon)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Account menu")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func updateLayer() {
        let lit = open || state.hoverOrPressed
        layer?.cornerRadius = 6
        layer?.backgroundColor = lit ? SB.c(\.sidebarForeground, open || state.active ? 0.12 : 0.08).cgColor(in: self) : nil
        icon.strokeColor = lit ? SB.c(\.sidebarForeground) : SB.c(\.sidebarMutedForeground)
    }
}

public final class SidebarAccountRowView: ControlView {
    public static let height: CGFloat = 44
    /// Its distance from the sidebar's left, right and bottom edges.
    public static let inset: CGFloat = 8
    /// Concentric with the window's bottom left corner, which it sits `inset` inside.
    public static let radius: CGFloat = DitherChrome.nested(in: DitherChrome.windowRadius, inset: inset)
    let avatar = SidebarAccountAvatarView()
    private let name = LabelView("", font: SB.font(13, .medium), color: SB.c(\.sidebarForeground))
    public let usage = AppUsageReadoutView()
    private let chevron = SidebarAccountChevronButton()
    public var onOpenSettings: (() -> Void)?
    public var onOpenUsage: (() -> Void)?
    /// A click on the avatar: Settings at Machines and connections.
    public var onOpenMachines: (() -> Void)?
    /// The updates "Update all" would run now (`UpdateEverythingLogic.offered`); the item hides at 0.
    public var updateAllCount = 0
    public var onUpdateAll: (() -> Void)?
    /// The menu is open: the chevron brightens and turns down, and the row keeps its lit fill.
    private var menuOpen = false { didSet { if menuOpen != oldValue { chevron.open = menuOpen; needsDisplay = true } } }
    /// Room at the right edge for the update button, which sits inside the row; the chevron moves left of it.
    public var trailingReserve: CGFloat = 0 { didSet { if trailingReserve != oldValue { needsLayout = true } } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        layer?.masksToBounds = false
        layer?.borderWidth = 0.5
        layer?.shadowColor = Themed.black(1).cgColor
        layer?.shadowRadius = 4
        addSubview(avatar)
        name.lineHeight = 16
        addSubview(name)
        addSubview(usage)
        addSubview(chevron)
        setAccessibilityRole(.group)
        // Only the chevron opens the menu (the user); the rest of the pill is not a button.
        chevron.action = { [weak self] in self?.showMenu() }
        avatar.action = { [weak self] in self?.onOpenMachines?() }
        set(name: NSFullUserName(), image: nil, initials: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func set(name: String, image: CGImage?, initials: String?) {
        self.name.text = name
        avatar.image.contents = image
        avatar.initials.text = initials ?? name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        avatar.initials.isHidden = image != nil
        setAccessibilityLabel("\(name), account menu")
        needsLayout = true
        needsDisplay = true
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    public override func updateLayer() {
        // A floating pill: an opaque resting fill a step up from the sidebar, so its shadow stays outside, lit a
        // step more on hover and while the menu is open, under a light hairline.
        let dark = effectiveAppearance.isDark
        let lift: CGFloat = menuOpen ? 2 : 0
        layer?.cornerRadius = Self.radius
        layer?.backgroundColor = NSColor(white: dark ? 0.085 + 0.03 * lift : 1 - 0.025 * lift, alpha: 1).cgColor
        layer?.borderColor = SB.c(\.sidebarForeground, dark ? 0.08 : 0.07).cgColor(in: self)
        layer?.shadowOpacity = dark ? 0.4 : 0.08
    }

    public override func layout() {
        super.layout()
        let h = bounds.height
        let a = SidebarAccountAvatarView.size + 2 * SidebarAccountAvatarView.ringGap
        avatar.frame = NSRect(x: 8 - SidebarAccountAvatarView.ringGap, y: (h - a) / 2, width: a, height: a)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.shadowOffset = CGSize(width: 0, height: layer?.isGeometryFlipped == true ? 2 : -2)
        layer?.shadowPath = SmoothCorners.path(bounds, Self.radius, flipped: false)
        CATransaction.commit()
        let tx: CGFloat = 8 + 28 + 10
        // Match the update button's 8pt inset and the utility row's 4pt gap.
        let end = bounds.width - 8 - trailingReserve
        let c = SidebarAccountChevronButton.size
        let right = end - c - 4
        name.frame = NSRect(x: tx, y: h / 2 - 16, width: max(0, right - tx), height: 16)
        usage.frame = NSRect(x: tx, y: h / 2, width: max(0, right - tx), height: 16)
        chevron.frame = NSRect(x: end - c, y: (h - c) / 2, width: c, height: c)
    }

    var menuItems: [MenuItem] {
        let lib = ThemeLibrary.shared
        let mode = lib.appearanceMode
        let appearance = [("light", "Light"), ("dark", "Dark"), ("system", "System")].map { key, title in
            MenuItem.radio(title, checked: mode == key) { _ in lib.setAppearanceMode(key) }
        }
        var items: [MenuItem] = [
            MenuItem("Settings", icon: .settings, shortcut: "⌘,") { [weak self] in self?.onOpenSettings?() },
            MenuItem("Usage", icon: .chartNoAxesColumn) { [weak self] in self?.onOpenUsage?() },
            .submenu("Appearance", icon: .moon, appearance),
        ]
        if updateAllCount > 0 {
            items.append(MenuItem("Update all (\(updateAllCount))", icon: .circleArrowUp) { [weak self] in self?.onUpdateAll?() })
        }
        return items
    }

    private func showMenu() {
        // Above the chevron, its left edge on the chevron's, reaching right out over the panel (the user's mockup,
        // 2026-10-23).
        let menu = MenuPopupView.show(menuItems, from: self, placement: PopupPlacement(side: .top, align: .start, sideOffset: 6, fallbackAxisSide: .none),
                                      anchorRect: chevron.frame)
        menuOpen = menu != nil
        menu?.hostPopup?.onClose = { [weak self] in self?.menuOpen = false }
    }
}
