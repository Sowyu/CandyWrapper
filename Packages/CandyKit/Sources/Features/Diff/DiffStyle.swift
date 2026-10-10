import AppKit
import DesignSystem

/// Geometry and colors of T3's diff viewer: `@pierre/diffs` 1.5.2 with T3's overrides
/// (StyledDiffCodeView.tsx, lib/diffRendering.ts). Values were measured from pierre rendering T3's
/// stylesheet in Chromium (scripts/gen-diff-spec.py): geometry from element boxes, colors from
/// computed styles (pierre mixes its tints in Lab), converted to sRGB and checked against the pixels.
@MainActor
enum DiffStyle {
    // MARK: Geometry (CSS px)

    nonisolated static let headerHeight: CGFloat = 32
    nonisolated static let separatorHeight: CGFloat = 24
    nonisolated static let lineHeight: CGFloat = 20
    /// `padding-bottom: 8px` under an expanded file's last row (`--diffs-gap-fallback`).
    nonisolated static let fileBottomPadding: CGFloat = 8
    /// The 2px `border-right` in the surface color between the number cell and the code.
    nonisolated static let gutterBorder: CGFloat = 2
    /// Change bar at the left edge of a changed line's number cell.
    nonisolated static let barWidth: CGFloat = 4

    static var codeFont: NSFont { DSFont.mono(13) }
    /// pierre's `markup.italic` tokens (Markdown emphasis).
    static var codeItalicFont: NSFont {
        DSFont.cached("mono-italic", 13, .regular) { NSFontManager.shared.convert(DSFont.mono(13), toHaveTrait: .italicFontMask) }
    }
    /// `1ch` of the code font.
    static var ch: CGFloat { codeFont.advancement(forGlyph: codeFont.glyph(withName: "zero")).width }

    /// Width of one number column: `padding-left: 2ch`, the digits of the file's largest line
    /// number (pierre's `--diffs-min-number-column-width-default`), `padding-right: 1ch`, then the
    /// 2px border.
    nonisolated static func gutterWidth(digits: Int, ch: CGFloat) -> CGFloat { CGFloat(3 + max(1, digits)) * ch + gutterBorder }

    // MARK: Colors (light, dark)

    static func rgb(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func c(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        let l = c(light), d = c(dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l }
    }

    /// `color-mix(in srgb, a p, b)` of two dynamic colors, resolved per appearance.
    static func mix(_ a: NSColor, _ p: CGFloat, _ b: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = NSColor.black
            appearance.performAsCurrentDrawingAppearance {
                let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
                result = NSColor(srgbRed: x.redComponent * p + y.redComponent * (1 - p),
                                 green: x.greenComponent * p + y.greenComponent * (1 - p),
                                 blue: x.blueComponent * p + y.blueComponent * (1 - p),
                                 alpha: x.alphaComponent * p + y.alphaComponent * (1 - p))
            }
            return result
        }
    }

    /// `--code-background`, which T3 sets to `--background`.
    static let surface = Themed.color(\.background)
    static let codeForeground = Themed.color(\.codeForeground)
    /// pierre-light and pierre-dark `editor.foreground`, the color of untokenized code.
    static let codeText = rgb(0x0a0a0a, 0xfafafa)

    static let additionBase = rgb(0x18a46c, 0x07c480)
    static let deletionBase = rgb(0xd52c36, 0xff2e3f)
    static let modifiedBase = rgb(0x009fff, 0x009fff)

    static let additionLine = rgb(0xecf9f4, 0x0d1713)
    static let additionNumber = rgb(0xeef9f5, 0x0e1713)
    static let deletionLine = rgb(0xfef0f0, 0x1c100f)
    static let deletionNumber = rgb(0xfef1f0, 0x1c110f)
    /// The lighter stripe of the deletion bar (`linear-gradient(0deg, alt 50%, base 50%)`, 2px tiles).
    static let deletionBarAlt = rgb(0xffe8e4, 0x381917)
    /// `--diffs-fg-number`: the theme foreground mixed 65% in Lab with the surface.
    static let number = rgb(0x575757, 0x9d9d9d)

    /// Split view: the number cell beside a missing line, and the diagonal buffer stripes.
    static let gutterBuffer = rgb(0xfbfbfb, 0x131313)
    static let bufferStripe = rgb(0xe8e8e8, 0x1d1d1d)

    static let separatorText = mix(codeForeground, 0.52, surface)
    static let separatorRule = mix(surface, 0.92, codeForeground)
    /// Header hover: `inset 3px 0` in the foreground at 24%.
    static let headerHoverBar = codeForeground.withAlphaComponent(0.24)
    static let noNewlineText = codeText.withAlphaComponent(0.6)

    static func iconColor(_ change: UnifiedDiff.Change?) -> NSColor {
        switch change {
        case .new: additionBase
        case .deleted: deletionBase
        case .change, .renamePure, .renameChanged: modifiedBase
        case nil: Themed.color(\.mutedForeground, 0.8)
        }
    }

    /// The split view's empty side: `repeating-linear-gradient(-45deg, transparent 0 4.24px,
    /// stripe 4.24px 5.66px)` on an 8px tile at `background-position: 5px 0`.
    static func bufferPattern(dark: Bool) -> CGColor {
        pattern("buffer", dark: dark, size: 8) { ctx in
            ctx.setFillColor(resolved(bufferStripe, dark: dark))
            // Stripes run along x + y = c; each 8px tile holds one, 2px wide along x. Chromium
            // draws them with hard edges.
            ctx.setShouldAntialias(false)
            for k in -1...2 {
                let a = CGFloat(k) * 8 + 5.5, b = a + 2
                ctx.move(to: CGPoint(x: a, y: 0)); ctx.addLine(to: CGPoint(x: b, y: 0))
                ctx.addLine(to: CGPoint(x: b - 8, y: 8)); ctx.addLine(to: CGPoint(x: a - 8, y: 8))
                ctx.closePath()
            }
            ctx.fillPath()
        }
    }

    /// The deletion bar: `linear-gradient(0deg, alt 50%, base 50%)` in 2px tiles, so 1px stripes
    /// of the deletion color from the top, alternating with a pale tint.
    static func deletionBarPattern(dark: Bool) -> CGColor {
        pattern("deletionBar", dark: dark, size: 2) { ctx in
            ctx.setFillColor(resolved(deletionBarAlt, dark: dark))
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            ctx.setFillColor(resolved(deletionBase, dark: dark))
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        }
    }

    private static func resolved(_ color: NSColor, dark: Bool) -> CGColor {
        var cg = color.cgColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }

    /// A pattern color from a tile drawn at 2x in a top-left coordinate space, made once per theme.
    private static func pattern(_ name: String, dark: Bool, size: CGFloat, draw: (CGContext) -> Void) -> CGColor {
        let key = "\(name) \(dark)"
        if let cached = patternCache[key] { return cached }
        let scale: CGFloat = 2
        let px = Int(size * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .retagging(with: .sRGB)!
        rep.size = NSSize(width: size, height: size)
        if let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
            ctx.translateBy(x: 0, y: size)
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx)
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        let color = NSColor(patternImage: image).cgColor
        patternCache[key] = color
        return color
    }
    private static var patternCache: [String: CGColor] = [:]
}
