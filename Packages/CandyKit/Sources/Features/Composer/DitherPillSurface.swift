import AppKit
import DesignSystem

/// Redesign's floating chrome for everything around the composer (the user, 2026-10-22: "no more things sticking out of
/// the prompt field, only floating rounded rectangle pills"): the composer's solid surface, a hairline border and a
/// soft drop shadow, on continuous corners. Pills (chips, Stash, notices) are 30pt; they and the panels (approvals,
/// the queue, the stash list) share the composer's one surface corner. Nothing draws while idle: the shadow has a fixed path.
public enum DitherPill {
    public static let height: CGFloat = RedesignTokens.Space.pill
    /// The composer's corner. Rows of pills sit `inset` in from the composer's sides, so a pill's corner never hangs
    /// off the composer's curve (the user, 2026-10-22); with one corner for both, that is none.
    public static let radius: CGFloat = DitherChrome.cardRadius
    public static let inset: CGFloat = DitherChrome.panelRadius - radius
    /// Between the composer and the first row, between rows, and between pills in a row.
    public static let gap: CGFloat = 8
    public static let spacing: CGFloat = 6
    /// Inside every pill around the composer, so a row of them reads as one: the glyph (or the chevron at the end) this
    /// far in from the pill's edge, a 14pt glyph box, and this gap between the glyph and the text and before the chevron.
    public static let pad: CGFloat = 8
    public static let glyph: CGFloat = 14
    public static let glyphGap: CGFloat = 6
    /// Where a pill's text starts.
    public static let textX: CGFloat = pad + glyph + glyphGap

    /// A quiet control (the new-thread page's project, machine and notices, and the row under a thread's composer) is
    /// plain text and glyph on a patch of the panel's own ground, no rim and no shadow (Capy's footer; the user,
    /// 2026-11-26: "not everything has to be pills"). The patch only just covers what sits behind the words: 22pt
    /// tall in the 30pt control, 6pt around the glyph and chevron, on the controls' corner. Hover and an open menu
    /// fill the same shape.
    public static func quietPatch(_ bounds: CGRect) -> CGRect { bounds.insetBy(dx: quietInsetX, dy: quietInsetY) }
    public static let quietInsetX: CGFloat = 2
    public static let quietInsetY: CGFloat = 4
    public static let quietRadius: CGFloat = RedesignTokens.Radius.control

    /// Places a control's hover fill: the quiet patch for a quiet control, else the whole pill. Call inside a
    /// transaction with actions off.
    @MainActor public static func placeFill(_ fill: CALayer, in bounds: CGRect, quiet: Bool) {
        fill.frame = quiet ? quietPatch(bounds) : bounds
        fill.cornerRadius = quiet ? quietRadius : radius
    }

    /// The solid surface fill: a timeline card scrolled under a panel never reads through it (the user's 1.14.10
    /// subagent panel over the changed-files card, 2026-10-28).
    @MainActor public static func fill(in view: NSView) -> CGColor { RedesignTokens.Surface.fill(in: view) }

    /// The resting shadow.
    @MainActor public static func shadow(_ layer: CALayer, path: CGRect, radius: CGFloat, dark: Bool) {
        RedesignTokens.Shadow.resting.apply(to: layer, path: SmoothCorners.path(path, radius, flipped: false), dark: dark)
    }
}

/// The pill chrome as a view, placed under a control that draws no surface of its own (the chips, the checkout and
/// branch controls). Lets clicks through.
public final class DitherPillSurface: DSView {
    public var radius: CGFloat = DitherPill.radius { didSet { if radius != oldValue { needsLayout = true } } }
    /// The panel's own ground instead of the raised surface, for a large surface whose cards must stand a step
    /// above it (Settings).
    public var ground = false { didSet { if ground != oldValue { needsDisplay = true } } }
    /// A quiet control (the new-thread page's project, machine and notices): the panel's own ground as a solid fill, so
    /// it stays readable over a picture and vanishes into a plain page, with no rim and no shadow.
    public var quiet = false { didSet { if quiet != oldValue { needsDisplay = true; needsLayout = true } } }
    /// The sidebar's color instead of the raised surface: the header pills (the user, 2026-11-27: "raise the colour of
    /// these pills to the colour of the sidebar").
    public var sidebarFill = false { didSet { if sidebarFill != oldValue { needsDisplay = true } } }
    private let shade = DSView()
    private let face = DSView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        face.layer?.borderWidth = 1
        face.layer?.masksToBounds = true
        for v in [shade, face] { addSubview(v) }
        setAccessibilityElement(false)
        // Increase Contrast changes the rim.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func displayOptionsChanged(_ note: Notification) { needsDisplay = true }

    public override func updateLayer() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        face.layer?.backgroundColor = ground || quiet ? Themed.color(\.background).cgColor(in: self)
            : sidebarFill ? Themed.color(\.sidebar, 1, sidebar: true).cgColor(in: self) : DitherPill.fill(in: self)
        shade.isHidden = quiet
        face.layer?.borderWidth = quiet ? 0 : 1
        face.layer?.borderColor = DitherChrome.rim(dark: effectiveAppearance.isDark).cgColor
        CATransaction.commit()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let r = quiet ? DitherPill.quietRadius : min(radius, bounds.height / 2)
        for v in [shade, face] { v.frame = quiet ? DitherPill.quietPatch(bounds) : bounds }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        face.layer?.cornerRadius = r
        shade.layer?.masksToBounds = false
        DitherPill.shadow(shade.layer!, path: shade.bounds, radius: r, dark: effectiveAppearance.isDark)
        shade.layer?.mask = DitherPill.outsideMask(shade.bounds, radius: r, existing: shade.layer?.mask)
        CATransaction.commit()
    }
}

extension DitherPill {
    /// Keeps a shadow outside its shape. The surface is opaque now, but a shadow under a 1pt translucent rim would
    /// still darken the rim.
    @MainActor static func outsideMask(_ rect: CGRect, radius: CGFloat, existing: CALayer?) -> CALayer {
        let mask = existing as? CAShapeLayer ?? CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(rect.insetBy(dx: -24, dy: -24))
        path.addPath(SmoothCorners.path(rect, radius, flipped: false))
        mask.fillRule = .evenOdd
        mask.frame = CGRect(origin: .zero, size: rect.size)
        mask.path = path
        return mask
    }
}
