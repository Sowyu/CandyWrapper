import CoreText
import Foundation

/// An OpenType math font and its MATH table (https://learn.microsoft.com/typography/opentype/spec/math), read once.
/// Latin Modern Math is bundled because it is Computer Modern, the face KaTeX draws; STIX Two Math, which ships
/// with macOS, stands in if the bundle lacks it. Values come back in font units; `MathFont.Sized` scales them.
final class MathFont: @unchecked Sendable {
    /// The face every formula uses. Nil only when neither font has a MATH table, and then formulas show their source.
    static let shared: MathFont? = {
        if let url = Bundle.module.url(forResource: "latinmodern-math", withExtension: "otf"),
           let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let descriptor = descriptors.first, let font = MathFont(CTFontCreateWithFontDescriptor(descriptor, 10, nil)) {
            return font
        }
        return MathFont(CTFontCreateWithName("STIXTwoMath-Regular" as CFString, 10, nil))
    }()

    let base: CTFont
    let unitsPerEm: CGFloat
    let constants: [Constant: CGFloat]
    let scriptScale: CGFloat
    let scriptScriptScale: CGFloat
    private let italics: [CGGlyph: CGFloat]
    private let topAccents: [CGFloat?]
    private let topAccentIndex: [CGGlyph: Int]
    private let vertical: [CGGlyph: Construction]
    private let horizontal: [CGGlyph: Construction]
    let minConnectorOverlap: CGFloat

    struct Variant { let glyph: CGGlyph; let advance: CGFloat }
    struct Part { let glyph: CGGlyph; let startConnector: CGFloat; let endConnector: CGFloat; let fullAdvance: CGFloat; let extender: Bool }
    struct Construction { let variants: [Variant]; let parts: [Part] }

    /// MathConstants' MathValueRecords, in table order.
    enum Constant: Int, CaseIterable {
        case mathLeading, axisHeight, accentBaseHeight, flattenedAccentBaseHeight, subscriptShiftDown, subscriptTopMax,
             subscriptBaselineDropMin, superscriptShiftUp, superscriptShiftUpCramped, superscriptBottomMin, superscriptBaselineDropMax,
             subSuperscriptGapMin, superscriptBottomMaxWithSubscript, spaceAfterScript, upperLimitGapMin, upperLimitBaselineRiseMin,
             lowerLimitGapMin, lowerLimitBaselineDropMin, stackTopShiftUp, stackTopDisplayStyleShiftUp, stackBottomShiftDown,
             stackBottomDisplayStyleShiftDown, stackGapMin, stackDisplayStyleGapMin, stretchStackTopShiftUp, stretchStackBottomShiftDown,
             stretchStackGapAboveMin, stretchStackGapBelowMin, fractionNumeratorShiftUp, fractionNumeratorDisplayStyleShiftUp,
             fractionDenominatorShiftDown, fractionDenominatorDisplayStyleShiftDown, fractionNumeratorGapMin, fractionNumDisplayStyleGapMin,
             fractionRuleThickness, fractionDenominatorGapMin, fractionDenomDisplayStyleGapMin, skewedFractionHorizontalGap,
             skewedFractionVerticalGap, overbarVerticalGap, overbarRuleThickness, overbarExtraAscender, underbarVerticalGap,
             underbarRuleThickness, underbarExtraDescender, radicalVerticalGap, radicalDisplayStyleVerticalGap, radicalRuleThickness,
             radicalExtraAscender, radicalKernBeforeDegree, radicalKernAfterDegree
        // Not MathValueRecords, stored after them.
        case delimitedSubFormulaMinHeight, displayOperatorMinHeight, radicalDegreeBottomRaisePercent
    }

    init?(_ font: CTFont) {
        guard let data = CTFontCopyTable(font, CTFontTableTag(0x4D41_5448), []) as Data?, data.count > 10 else { return nil }
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
        func i16(_ o: Int) -> CGFloat { CGFloat(Int16(bitPattern: UInt16(u16(o)))) }
        func coverage(_ o: Int) -> [CGGlyph: Int] {
            var out: [CGGlyph: Int] = [:]
            switch u16(o) {
            case 1:
                for i in 0..<u16(o + 2) { out[CGGlyph(u16(o + 4 + 2 * i))] = i }
            case 2:
                for r in 0..<u16(o + 2) {
                    let rec = o + 4 + 6 * r, start = u16(rec), end = u16(rec + 2), index = u16(rec + 4)
                    if end >= start { for g in start...end { out[CGGlyph(g)] = index + g - start } }
                }
            default: break
            }
            return out
        }
        base = font
        unitsPerEm = CGFloat(CTFontGetUnitsPerEm(font))
        let c = u16(4), info = u16(6), variants = u16(8)
        guard c > 0, variants > 0 else { return nil }
        scriptScale = i16(c) / 100
        scriptScriptScale = i16(c + 2) / 100
        var constants: [Constant: CGFloat] = [:]
        constants[.delimitedSubFormulaMinHeight] = CGFloat(u16(c + 4))
        constants[.displayOperatorMinHeight] = CGFloat(u16(c + 6))
        for k in Constant.allCases where k.rawValue <= Constant.radicalKernAfterDegree.rawValue {
            constants[k] = i16(c + 8 + 4 * k.rawValue)
        }
        constants[.radicalDegreeBottomRaisePercent] = i16(c + 8 + 4 * (Constant.radicalKernAfterDegree.rawValue + 1))
        self.constants = constants

        var italics: [CGGlyph: CGFloat] = [:], topAccents: [CGFloat?] = [], topAccentIndex: [CGGlyph: Int] = [:]
        if info > 0 {
            let ic = u16(info), ta = u16(info + 2)
            if ic > 0 {
                let o = info + ic
                for (glyph, i) in coverage(o + u16(o)) where i < u16(o + 2) { italics[glyph] = i16(o + 4 + 4 * i) }
            }
            if ta > 0 {
                let o = info + ta, n = u16(o + 2)
                topAccentIndex = coverage(o + u16(o))
                topAccents = (0..<n).map { i16(o + 4 + 4 * $0) }
            }
        }
        self.italics = italics
        self.topAccents = topAccents
        self.topAccentIndex = topAccentIndex

        let v = variants
        minConnectorOverlap = CGFloat(u16(v))
        func constructions(coverageOffset: Int, count: Int, offsets: Int) -> [CGGlyph: Construction] {
            guard coverageOffset > 0 else { return [:] }
            var out: [CGGlyph: Construction] = [:]
            for (glyph, i) in coverage(v + coverageOffset) where i < count {
                let o = v + u16(offsets + 2 * i)
                let assembly = u16(o), n = u16(o + 2)
                let list = (0..<n).map { Variant(glyph: CGGlyph(u16(o + 4 + 4 * $0)), advance: CGFloat(u16(o + 6 + 4 * $0))) }
                var parts: [Part] = []
                if assembly > 0 {
                    let a = o + assembly
                    for p in 0..<u16(a + 4) {
                        let r = a + 6 + 10 * p
                        parts.append(Part(glyph: CGGlyph(u16(r)), startConnector: CGFloat(u16(r + 2)), endConnector: CGFloat(u16(r + 4)),
                                          fullAdvance: CGFloat(u16(r + 6)), extender: u16(r + 8) & 1 == 1))
                    }
                }
                out[glyph] = Construction(variants: list, parts: parts)
            }
            return out
        }
        let vCount = u16(v + 6), hCount = u16(v + 8)
        vertical = constructions(coverageOffset: u16(v + 2), count: vCount, offsets: v + 10)
        horizontal = constructions(coverageOffset: u16(v + 4), count: hCount, offsets: v + 10 + 2 * vCount)
    }

    func italic(_ g: CGGlyph) -> CGFloat { italics[g] ?? 0 }
    func topAccent(_ g: CGGlyph) -> CGFloat? { topAccentIndex[g].flatMap { $0 < topAccents.count ? topAccents[$0] : nil } }
    func construction(_ g: CGGlyph, vertical v: Bool) -> Construction? { v ? vertical[g] : horizontal[g] }

    /// The glyph for one character (a scalar outside the BMP takes a surrogate pair), 0 when the font lacks it.
    func glyph(_ scalar: Unicode.Scalar) -> CGGlyph {
        var units = Array(String(scalar).utf16), glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(base, &units, &glyphs, units.count) else { return 0 }
        return glyphs[0]
    }

    /// Advance and ink bounds, in font units.
    func metrics(_ g: CGGlyph) -> (advance: CGFloat, bounds: CGRect) {
        var glyph = g, advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let bounds = CTFontGetBoundingRectsForGlyphs(base, .horizontal, &glyph, nil, 1)
        let scale = unitsPerEm / CTFontGetSize(base)
        return (advance.width * scale, CGRect(x: bounds.minX * scale, y: bounds.minY * scale, width: bounds.width * scale, height: bounds.height * scale))
    }

    /// The font at one point size, for drawing.
    private var sized: [CGFloat: CTFont] = [:]
    private let lock = NSLock()
    func font(size: CGFloat) -> CTFont {
        lock.lock(); defer { lock.unlock() }
        if let f = sized[size] { return f }
        let f = CTFontCreateCopyWithAttributes(base, size, nil, nil)
        sized[size] = f
        return f
    }
}
