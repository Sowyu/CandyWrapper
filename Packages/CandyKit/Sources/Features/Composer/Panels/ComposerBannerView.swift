import AppKit
import DesignSystem

/// `ComposerBanner.Root` with `placement="attached"` (chat/ComposerBanner.tsx:37-71, 148-178):
/// the rounded-top glass card that docks above the composer and slides `overlap` (17) under it.
/// Its fill and outline stop 16px above its bottom (`mask-t-from-4`), so the composer's own
/// surface covers the seam. Spec: J-composer-visuals 6.1.
///
/// Integration: the composer lane places the banner `drawerInset` (22) in from each side of the
/// composer, its bottom `overlap` below the composer's top, and BELOW the composer in z-order.
public class ComposerBannerView: DSView {
    public enum Variant { case neutral, warning, error }

    /// `--chat-composer-attachment-overlap`: `calc(1rem + 1px)`.
    public static let overlap: CGFloat = 17
    /// `--chat-composer-drawer-inset`, per side.
    public static let drawerInset: CGFloat = 22
    static let radius: CGFloat = 18
    /// Matches the composer's corner, Capy's tighter one under Dither.
    var cardRadius: CGFloat { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? DitherChrome.cardRadius : Self.radius }

    var variant: Variant { didSet { if variant != oldValue { needsDisplay = true } } }
    /// Docked under another attachment (the queue strip): no top corners and no top border, so
    /// the two share one outline (ComposerBanner.Attachment's adjacent-sibling rule).
    public var joinsAbove = false { didSet { if joinsAbove != oldValue { needsLayout = true } } }
    /// `placement` (ComposerBanner.tsx:37-71): `attached` docks over the next attachment with the
    /// 17pt overlap masked off; `floating` is a whole rounded card with no overlap, used for the
    /// notices the banner stack shows above the column when it expands.
    public enum Placement { case attached, floating }
    public var placement = Placement.attached { didSet { if placement != oldValue { needsLayout = true; needsDisplay = true } } }
    /// Redesign floats every attachment as its own card: whole, frosted, with a drop shadow (`DitherPill`).
    /// Redesign: the composer's own corner and no drop shadow in dark, for a panel that reads as part of it.
    var matchesComposer = false { didSet { if matchesComposer != oldValue { needsLayout = true } } }
    var ditherFloating: Bool { placement == .floating && ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    /// What the content leaves at the bottom for the composer to cover: the overlap when attached, nothing floating.
    public var tail: CGFloat { placement == .attached ? Self.overlap : 0 }
    /// The shadow under a Redesign card, built the first time one floats.
    private var shade: CALayer?
    /// The `ComposerBanner.Dismiss` X, if this banner has one; the banner stack disables it while
    /// the banner leaves.
    public var dismissControl: ButtonView? { nil }
    /// Clips the surface 16px above the bottom (the mask).
    private let clip = DSView()
    /// The backdrop blur under the 80% fill.
    private let blur = BackdropBlurView()
    private let surface = DSView()
    private let tint = CALayer()
    /// Dark only: `--background-image-composer-seam-above`, a 10px shade fading up from the seam.
    private let seam = CAGradientLayer()

    init(variant: Variant) {
        self.variant = variant
        super.init(frame: .zero)
        clipsToBounds = true
        clip.clipsToBounds = true
        addSubview(clip)
        // Glass: the composer surface at 80% over a 12px backdrop blur, saturate 1.14.
        blur.cornerRadius = cardRadius
        clip.addSubview(blur)
        surface.layer?.cornerRadius = cardRadius
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        surface.layer?.addSublayer(tint)
        surface.layer?.addSublayer(seam)
        clip.addSubview(surface)
    }

    public override func updateLayer() {
        blur.cornerRadius = cardRadius
        surface.layer?.cornerRadius = cardRadius
        needsLayout = true
        let dark = effectiveAppearance.isDark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.layer?.backgroundColor = ditherFloating ? DitherPill.fill(in: self)
            : Themed.color(light: \.card, 0.8, dark: \.surfaceRaised, 0.8).cgColor(in: self)
        switch variant {
        case .neutral:
            tint.backgroundColor = nil
            surface.layer?.borderColor = ditherFloating ? DitherChrome.rim(dark: dark).cgColor : (dark ? Themed.white(0.05) : Themed.black(0.08)).cgColor
        case .warning:
            tint.backgroundColor = Themed.color(\.warning, 0.08).cgColor(in: self)
            surface.layer?.borderColor = Themed.color(\.warning, 0.28).cgColor(in: self)
        case .error:
            tint.backgroundColor = Themed.color(\.error, 0.08).cgColor(in: self)
            surface.layer?.borderColor = Themed.color(\.error, 0.32).cgColor(in: self)
        }
        seam.isHidden = !dark || ditherFloating
        seam.colors = [Themed.black(0).cgColor, Themed.black(0.18).cgColor]
        CATransaction.commit()
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let floating = placement == .floating
        clip.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - (floating ? 0 : 16)))
        // Taller than the clip so the bottom corners never show. Joined: 1pt above the clip, so
        // the top border falls outside it, and square. Floating: the whole card, `rounded-2xl`.
        let top: CGFloat = joinsAbove && !floating ? -1 : 0
        surface.frame = NSRect(x: 0, y: top, width: w, height: floating ? h : h + cardRadius - top)
        blur.frame = surface.frame
        // CSS scales radii down to fit the box (a 34pt floating card gets 17); Core Animation does not.
        // Redesign: a pill's control corner, a panel's card corner.
        let dither = ditherFloating
        let radius = top < 0 ? 0 : dither && matchesComposer ? DitherChrome.panelRadius : dither ? (h <= DitherPill.height ? DitherPill.radius : DitherChrome.cardRadius)
            : floating ? min(cardRadius, h / 2) : cardRadius
        surface.layer?.cornerRadius = radius
        blur.cornerRadius = radius
        clipsToBounds = !dither
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if dither {
            let layer = shade ?? CALayer()
            if shade == nil, let root = self.layer { root.insertSublayer(layer, at: 0); shade = layer }
            layer.isHidden = matchesComposer && effectiveAppearance.isDark
            layer.frame = bounds
            DitherPill.shadow(layer, path: layer.bounds, radius: radius, dark: effectiveAppearance.isDark)
            layer.mask = DitherPill.outsideMask(layer.bounds, radius: radius, existing: layer.mask)
        } else {
            shade?.isHidden = true
        }
        tint.frame = surface.bounds
        // The shade sits just above the overlap line (the bottom edge when floating), darkest at the seam.
        seam.frame = CGRect(x: 0, y: h - (floating ? 0 : Self.overlap) - 10 - top, width: w, height: 10)
        seam.startPoint = CGPoint(x: 0.5, y: surface.isFlipped ? 0 : 1)
        seam.endPoint = CGPoint(x: 0.5, y: surface.isFlipped ? 1 : 0)
        CATransaction.commit()
    }
}

/// Text on the banner's glass: Chromium skips font smoothing there (PROGRESS findings).
@MainActor func glassLabel(_ text: String = "", font: NSFont, color: NSColor, lineHeight: CGFloat) -> LabelView {
    let label = LabelView(text, font: font, color: color)
    label.lineHeight = lineHeight
    label.smoothsFont = false
    return label
}

@MainActor func glassBlock(font: NSFont, color: NSColor, lineHeight: CGFloat) -> TextBlockView {
    let block = TextBlockView()
    block.font = font
    block.color = color
    block.lineHeight = lineHeight
    block.smoothsFont = false
    return block
}
