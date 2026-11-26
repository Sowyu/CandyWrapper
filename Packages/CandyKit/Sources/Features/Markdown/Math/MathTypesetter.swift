import AppKit
import CoreText

/// A typeset formula: glyphs, rules and strokes around a baseline at the origin, y up. Width, height above the baseline
/// and depth below it follow KaTeX's box model. Parts with no color of their own take the text color.
final class MathLayout: @unchecked Sendable {
    struct Glyph { let glyph: CGGlyph; let size: CGFloat; let position: CGPoint; var color: CGColor? = nil }
    /// A drawn shape: Words draws radicals and grown delimiters as paths. `stroke` nil fills it.
    struct Shape { let path: CGPath; var stroke: CGFloat? = nil; var color: CGColor? = nil }
    let width: CGFloat
    let height: CGFloat
    let depth: CGFloat
    let glyphs: [Glyph]
    let rules: [CGRect]
    let ruleColors: [CGColor?]
    let shapes: [Shape]
    /// A display formula's `\tag`, drawn at the column's right edge on the formula's baseline.
    let tag: MathLayout?

    init(_ box: MathBox, tag: MathBox? = nil) {
        width = box.width; height = box.height; depth = box.depth
        glyphs = box.glyphs; rules = box.rules; ruleColors = box.ruleColors; shapes = box.shapes
        self.tag = tag.map { MathLayout($0) }
    }

    /// `point` with its y on the nearest device row, a tie going down the page as Blink rounds, and with `quarterX` its x
    /// on the nearest quarter of a device pixel, Skia's subpixel glyph positions.
    static func snapped(_ point: CGPoint, in ctx: CGContext, quarterX: Bool = false) -> CGPoint {
        let m = ctx.ctm
        var d = point.applying(m)
        // Core Graphics device space has y up, so down the page is toward a smaller y.
        d.y = (d.y - 0.5).rounded(.up)
        if quarterX { d.x = (d.x * 4).rounded() / 4 }
        return d.applying(m.inverted())
    }

    /// Draws with the baseline's left end at `origin`, in a flipped (y down) context. Blink puts the formula's baseline on a
    /// device row and Skia draws each glyph on a device row at a quarter-pixel x, so both snap here; rules and shapes move
    /// with the baseline.
    func draw(in ctx: CGContext, at origin: CGPoint, color: CGColor) {
        guard let font = MathFont.shared else { return }
        let origin = Self.snapped(origin, in: ctx)
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: 1, y: -1)
        for (i, r) in rules.enumerated() {
            ctx.setFillColor((i < ruleColors.count ? ruleColors[i] : nil) ?? color)
            ctx.fill(r)
        }
        // Blink draws Words' SVG text through Skia, which asks Core Text for each glyph's mask at its device size with font
        // smoothing on: the same weight as the app's other text, about 18% more ink than a filled outline at 1x.
        // Measured against the 5258 references: mean 3.61% differing pixels as outlines, 2.09% this way.
        ctx.saveGState()
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.textMatrix = .identity
        for g in glyphs {
            var glyph = g.glyph
            ctx.setFillColor(g.color ?? color)
            CTFontDrawGlyphs(font.font(size: g.size), &glyph, [Self.snapped(g.position, in: ctx, quarterX: true)], 1, ctx)
        }
        ctx.restoreGState()
        // After the glyphs, in Words' SVG order for radicals and delimiters, and over them for `\cancel`.
        for s in shapes {
            ctx.addPath(s.path)
            if let w = s.stroke {
                ctx.setStrokeColor(s.color ?? color)
                ctx.setLineWidth(w)
                ctx.setLineJoin(.miter)
                ctx.setLineCap(.butt)
                ctx.strokePath()
            } else {
                ctx.setFillColor(s.color ?? color)
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }
}

/// A box under construction.
struct MathBox {
    var width: CGFloat = 0
    var height: CGFloat = 0
    var depth: CGFloat = 0
    var glyphs: [MathLayout.Glyph] = []
    var rules: [CGRect] = []
    /// Colors for `rules` by index; shorter than `rules` where the rest take the text color.
    var ruleColors: [CGColor?] = []
    var shapes: [MathLayout.Shape] = []
    /// A lone symbol's italic correction, included in `width`.
    var italic: CGFloat = 0
    /// A lone symbol: scripts sit at the font's shifts instead of hanging off the box (TeX rule 18a).
    var isChar = false
    /// A big operator, whose width already holds its italic correction (Words' $AF.op).
    var isOp = false
    /// The glyph of a lone symbol, for accent attachment.
    var glyph: CGGlyph?

    mutating func add(_ b: MathBox, x: CGFloat, y: CGFloat) {
        glyphs += b.glyphs.map { .init(glyph: $0.glyph, size: $0.size, position: CGPoint(x: $0.position.x + x, y: $0.position.y + y), color: $0.color) }
        ruleColors += Array(repeating: nil, count: max(0, rules.count - ruleColors.count))
        ruleColors += (0..<b.rules.count).map { $0 < b.ruleColors.count ? b.ruleColors[$0] : nil }
        rules += b.rules.map { $0.offsetBy(dx: x, dy: y) }
        var move = CGAffineTransform(translationX: x, y: y)
        shapes += b.shapes.map { .init(path: $0.path.copy(using: &move) ?? $0.path, stroke: $0.stroke, color: $0.color) }
        height = max(height, b.height + y)
        depth = max(depth, b.depth - y)
    }

    func shifted(up dy: CGFloat) -> MathBox {
        var out = MathBox(width: width, italic: italic, isChar: isChar, glyph: glyph)
        out.height = -.greatestFiniteMagnitude; out.depth = -.greatestFiniteMagnitude
        out.add(self, x: 0, y: dy)
        return out
    }

    /// Every part without a color of its own in `color` (`\color` nests: the innermost wins).
    func tinted(_ color: CGColor) -> MathBox {
        var out = self
        out.glyphs = glyphs.map { var g = $0; if g.color == nil { g.color = color }; return g }
        out.ruleColors = (0..<rules.count).map { ($0 < ruleColors.count ? ruleColors[$0] : nil) ?? color }
        out.shapes = shapes.map { var s = $0; if s.color == nil { s.color = color }; return s }
        return out
    }
}

/// Lays out `MathNode`s as T3 5258's Words does (@pierre/words 0.2.2-t3.4, src/math.wat): the TeXbook's Appendix G rules
/// with STIX Two Math's MATH constants, its glyph metrics in tens of units, and drawn radicals and grown delimiters.
struct MathTypesetter {
    struct Unsupported: Error { let reason: String }

    struct Style: Equatable {
        var kind: MathStyleKind
        var cramped = false
        var smaller: MathStyleKind {
            switch kind { case .display, .text: .script; case .script, .scriptScript: .scriptScript }
        }
        var sup: Style { Style(kind: smaller, cramped: cramped) }
        var sub: Style { Style(kind: smaller, cramped: true) }
        var fraction: MathStyleKind {
            switch kind { case .display: .text; case .text: .script; case .script, .scriptScript: .scriptScript }
        }
        var num: Style { Style(kind: fraction, cramped: cramped) }
        var den: Style { Style(kind: fraction, cramped: true) }
        var crampedSelf: Style { Style(kind: kind, cramped: true) }
        var isScript: Bool { kind == .script || kind == .scriptScript }
    }

    let font: MathFont
    /// The font size of display and text style, KaTeX's `1.21em` of the surrounding text.
    let em: CGFloat

    func size(_ s: Style) -> CGFloat {
        switch s.kind {
        case .display, .text: em
        case .script: em * font.scriptScale
        case .scriptScript: em * font.scriptScriptScale
        }
    }
    func k(_ c: MathFont.Constant, _ s: Style) -> CGFloat { (font.constants[c] ?? 0) * size(s) / font.unitsPerEm }
    /// Words' lengths: thousandths of the em at style `s` (math.wat `$m.sc`).
    func words(_ v: CGFloat, _ s: Style) -> CGFloat { v * size(s) / 1000 }
    private func units(_ v: CGFloat, _ s: Style) -> CGFloat { v * size(s) / font.unitsPerEm }

    /// The formula and its `\tag`. KaTeX allows a tag only in display mode.
    static func layout(_ nodes: [MathNode], display: Bool, em: CGFloat, font: MathFont) throws -> (box: MathBox, tag: MathBox?) {
        let t = MathTypesetter(font: font, em: em)
        var tag: MathBox?
        var body: [MathNode] = []
        // `\color{red} x \tag{1}`: a tag in a top-level color switch still belongs to the formula.
        let hoisted = nodes.flatMap { node -> [MathNode] in
            guard case .colored(let c, let inner) = node, inner.contains(where: { if case .tag = $0 { true } else { false } }) else { return [node] }
            return [.colored(c, inner.filter { if case .tag = $0 { false } else { true } })] + inner.filter { if case .tag = $0 { true } else { false } }
        }
        for node in hoisted {
            guard case .tag(let text) = node else { body.append(node); continue }
            guard display else { throw Unsupported(reason: "\\tag outside display math") }
            tag = try t.text(text, .roman, Style(kind: .text))
        }
        return (try t.list(body, Style(kind: display ? .display : .text)), tag)
    }

    // MARK: Lists

    enum Item {
        case atom(MathClass, MathBox, Style)
        case kern(CGFloat)
        case middle(Unicode.Scalar?, Style)
    }

    func list(_ nodes: [MathNode], _ start: Style) throws -> MathBox {
        join(try items(nodes, start))
    }

    func items(_ nodes: [MathNode], _ start: Style) throws -> [Item] {
        var style = start
        var out: [Item] = []
        for node in nodes {
            switch node {
            // `\displaystyle` and friends pick the uncramped style (KaTeX styling.ts).
            case .style(let kind): style = Style(kind: kind)
            // mu shrinks with the style; em and pt keep text size, as KaTeX's units.ts measures them in scripts.
            case .space(let v, let mu): out.append(.kern(mu ? v * size(style) / 18 : v * em))
            case .middle(let d): out.append(.middle(d, style))
            case .colored(let color, let body):
                // Color keeps the body's own classes, so `a \color{red}{+} b` spaces like `a + b`.
                for item in try items(body, style) {
                    if case .atom(let cls, let box, let s) = item { out.append(.atom(cls, box.tinted(color.cgColor), s)) } else { out.append(item) }
                }
            default:
                let (cls, box) = try atom(node, style)
                out.append(.atom(cls, box, style))
            }
        }
        return out
    }

    /// Spacing between neighbours by class (TeXbook p. 170): 1 thin, 2 medium, 3 thick; negative only outside scripts.
    private static let spacing: [[Int]] = [
        [0, 1, -2, -3, 0, 0, 0, -1],
        [1, 1, 0, -3, 0, 0, 0, -1],
        [-2, -2, 0, 0, -2, 0, 0, -2],
        [-3, -3, 0, 0, -3, 0, 0, -3],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 1, -2, -3, 0, 0, 0, -1],
        [-1, -1, 0, -3, -1, -1, -1, -1],
        [-1, 1, -2, -3, -1, 0, -1, -1],
    ]

    func join(_ input: [Item]) -> MathBox {
        var items = input
        // A binary operator with nothing to join becomes ordinary (rules 5 and 6).
        var previous: Int?
        for i in items.indices {
            guard case .atom(var cls, let box, let style) = items[i] else { continue }
            if cls == .bin {
                if let p = previous, case .atom(let pc, _, _) = items[p], ![.bin, .op, .rel, .open, .punct].contains(pc) {} else { cls = .ord }
            }
            if [.rel, .close, .punct].contains(cls), let p = previous, case .atom(.bin, let pb, let ps) = items[p] { items[p] = .atom(.ord, pb, ps) }
            items[i] = .atom(cls, box, style)
            previous = i
        }
        if let p = previous, case .atom(.bin, let pb, let ps) = items[p] { items[p] = .atom(.ord, pb, ps) }

        var out = MathBox()
        var x: CGFloat = 0
        var last: MathClass?
        for item in items {
            switch item {
            case .kern(let w): x += w
            case .middle: break
            case .atom(let cls, let box, let style):
                if let l = last {
                    let code = Self.spacing[l.rawValue][cls.rawValue]
                    if code > 0 || (code < 0 && !style.isScript) {
                        x += words(111 + 56 * CGFloat(abs(code)), style)
                    }
                }
                out.add(box, x: x, y: 0)
                x += box.width
                last = cls
            }
        }
        out.width = x
        if items.count == 1, case .atom(_, let only, _) = items[0] { out.italic = only.italic; out.isChar = only.isChar; out.glyph = only.glyph }
        return out
    }

    // MARK: Atoms

    func atom(_ node: MathNode, _ style: Style) throws -> (MathClass, MathBox) {
        switch node {
        case .symbol(let s, let cls):
            return (cls, try symbol(s, style))
        case .largeOp(let s, let limits):
            return (.op, try largeOp(s, style, limits: limits).box)
        case .namedOp(let text, _):
            return (.op, try self.text(text, .roman, style))
        case .group(let body, let cls):
            return (cls, try list(body, style))
        case .scripts(let base, let sub, let sup):
            return try scripts(base, sub: sub, sup: sup, style)
        case .frac(let num, let den, let rule, let forced, let l, let r):
            return (.ord, try fraction(num, den, rule: rule, style: forced.map { Style(kind: $0) } ?? style, left: l, right: r))
        case .sqrt(let body, let index):
            return (.ord, try radical(body, index: index, style))
        case .leftRight(let l, let body, let r):
            return (.inner, try leftRight(l, body, r, style))
        case .middle(let d):
            return (.rel, try delimiter(d, total: em, style))
        case .sizedDelim(let d, let n, let cls):
            return (cls, try delimiter(d, total: [1.2, 1.8, 2.4, 3.0][n - 1] * size(style), style))
        case .accent(let a, let body, let stretchy):
            return (.ord, try accent(a, body, stretchy: stretchy, style))
        case .overline(let body):
            let b = try list(body, style.crampedSelf)
            var out = b
            let gap = k(.overbarVerticalGap, style), t = k(.overbarRuleThickness, style)
            out.rules.append(CGRect(x: 0, y: b.height + gap, width: b.width, height: t))
            out.height = b.height + gap + t + k(.overbarExtraAscender, style)
            out.isChar = false
            return (.ord, out)
        case .underline(let body):
            let b = try list(body, style)
            var out = b
            let gap = k(.underbarVerticalGap, style), t = k(.underbarRuleThickness, style)
            out.rules.append(CGRect(x: 0, y: -b.depth - gap - t, width: b.width, height: t))
            out.depth = b.depth + gap + t + k(.underbarExtraDescender, style)
            out.isChar = false
            return (.ord, out)
        case .overUnder(let base, let over, let under, let brace, let cls):
            return (cls, try stack(list(base, style), over: over, under: under, brace: brace, style))
        case .text(let s, let variant):
            return (.ord, try text(s, variant, style))
        case .array(let rows, let columns, let kind, let gaps, let hlines):
            return (.ord, try array(rows, columns: columns, kind: kind, gaps: gaps, hlines: hlines, style))
        case .phantom(let body, let w, let h):
            let b = try list(body, style)
            return (.ord, MathBox(width: w ? b.width : 0, height: h ? b.height : 0, depth: h ? b.depth : 0))
        case .boxed(let body):
            let b = try list(body, Style(kind: .display, cramped: style.cramped))
            let pad = 0.3 * size(style), t = 0.04 * size(style)
            var out = MathBox()
            out.add(b, x: pad + t, y: 0)
            out.width = b.width + 2 * (pad + t)
            out.height = b.height + pad + t; out.depth = b.depth + pad + t
            out.rules += [CGRect(x: 0, y: -out.depth, width: out.width, height: t), CGRect(x: 0, y: out.height - t, width: out.width, height: t),
                          CGRect(x: 0, y: -out.depth, width: t, height: out.height + out.depth),
                          CGRect(x: out.width - t, y: -out.depth, width: t, height: out.height + out.depth)]
            return (.ord, out)
        case .colored(let color, let body):
            // Under scripts: a lone atom keeps its class (`\textcolor{red}{=}^!` is still a relation).
            if body.count == 1 {
                let (cls, box) = try atom(body[0], style)
                return (cls, box.tinted(color.cgColor))
            }
            return (.ord, try list(body, style).tinted(color.cgColor))
        case .cancel(let body, let up, let down):
            // KaTeX's enclose.ts: a 0.046em line corner to corner, 0.2em past the box above and below.
            var out = try list(body, style)
            out.isChar = false
            let pad = 0.2 * size(style), w = 0.046 * size(style)
            let bottom = -out.depth - pad, top = out.height + pad
            func line(_ a: CGPoint, _ b: CGPoint) -> MathLayout.Shape {
                let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); return .init(path: p, stroke: w)
            }
            if up { out.shapes.append(line(CGPoint(x: 0, y: bottom), CGPoint(x: out.width, y: top))) }
            if down { out.shapes.append(line(CGPoint(x: 0, y: top), CGPoint(x: out.width, y: bottom))) }
            return (.ord, out)
        case .xArrow(let arrow, let above, let below):
            return (.rel, try xArrow(arrow, above: above, below: below, style))
        case .tag:
            // Only the top level of a display formula holds a tag; anywhere else (`x \tag{1}^2`) is beyond stage 1.
            throw Unsupported(reason: "misplaced \\tag")
        case .style, .space:
            return (.ord, MathBox())
        }
    }

    func glyphBox(_ g: CGGlyph, _ style: Style) -> MathBox {
        // Words' metrics table holds STIX Two Math's advance, ink bounds and italic correction in tens of units
        // (math.wat `$m.metrics`); the italic correction stays out of the width until scripts use it.
        let m = font.metrics(g), s = size(style)
        let scale = s / font.unitsPerEm
        func tens(_ v: CGFloat) -> CGFloat { (v / 10).rounded() * 10 * scale }
        return MathBox(width: tens(m.advance), height: max(0, tens(m.bounds.maxY)), depth: max(0, tens(-m.bounds.minY)),
                       glyphs: [.init(glyph: g, size: s, position: .zero)], italic: tens(font.italic(g)), isChar: true, glyph: g)
    }

    func symbol(_ s: Unicode.Scalar, _ style: Style) throws -> MathBox {
        let g = font.glyph(s)
        guard g != 0 else { throw Unsupported(reason: "no glyph for U+\(String(s.value, radix: 16))") }
        return glyphBox(g, style)
    }

    /// A big operator, centered on the math axis, with its display size in display style.
    func largeOp(_ s: Unicode.Scalar, _ style: Style, limits: Bool?) throws -> (box: MathBox, limits: Bool) {
        // Words' `$m.bigOp`: the base glyph scaled by 1.3 in display style, 1.8 for integrals, centered on the axis.
        // Its italic correction widens it, and a subscript tucks back under by as much.
        let g = font.glyph(s)
        guard g != 0 else { throw Unsupported(reason: "no operator glyph") }
        let f: CGFloat = style.kind == .display ? ((0x222B...0x2233).contains(s.value) ? 1.8 : 1.3) : 1
        let box = glyphBox(g, style)
        let half = (box.height + box.depth) * f / 2, axis = words(258, style)
        var out = MathBox()
        out.add(MathBox(glyphs: [.init(glyph: g, size: size(style) * f, position: .zero)]), x: 0, y: -((box.height - box.depth) * f / 2 - axis))
        out.width = box.width * f + box.italic * f
        out.height = half + axis; out.depth = half - axis
        out.italic = box.italic * f
        out.isOp = true
        let useLimits = limits ?? (style.kind == .display && !Symbols.integrals.contains(s))
        return (out, limits == true || (useLimits && style.kind == .display))
    }

    // MARK: Scripts

    func scripts(_ base: MathNode, sub: [MathNode]?, sup: [MathNode]?, _ style: Style) throws -> (MathClass, MathBox) {
        switch base {
        case .largeOp(let s, let limits):
            let op = try largeOp(s, style, limits: limits)
            if op.limits { return (.op, try limitsBox(op.box, sup: sup, sub: sub, style)) }
            return (.op, try attach(op.box, sub: sub, sup: sup, style))
        case .namedOp(let text, let limits) where limits && style.kind == .display:
            return (.op, try limitsBox(try self.text(text, .roman, style), sup: sup, sub: sub, style))
        case .overUnder(let b, nil, nil, let brace, .op):
            // `\overbrace{…}^{label}` and `\mathop{…}\limits`: the scripts stack over and under.
            return (.op, try stack(list(b, style), over: brace == "\u{23DF}" ? nil : sup, under: brace == "\u{23DE}" ? nil : sub,
                                   brace: brace, style, extraSub: brace == "\u{23DE}" ? sub : nil, extraSup: brace == "\u{23DF}" ? sup : nil))
        case .accent(_, let body, _) where body.count == 1:
            // KaTeX's accent.ts: `\hat{x}^2` places the scripts on the x, as if the accent weren't there.
            let char = try list(body, style.crampedSelf)
            let (_, accented) = try atom(base, style)
            var box = accented
            box.height = char.height
            box.isChar = char.isChar
            var out = try attach(box, sub: sub, sup: sup, style)
            out.height = max(out.height, accented.height)
            return (.ord, out)
        default:
            let (cls, box) = try atom(base, style)
            return (cls, try attach(box, sub: sub, sup: sup, style))
        }
    }

    /// TeX rule 18: scripts beside the base.
    func attach(_ base: MathBox, sub: [MathNode]?, sup: [MathNode]?, _ style: Style) throws -> MathBox {
        let supBox = try sup.map { try list($0, style.sup) }
        let subBox = try sub.map { try list($0, style.sub) }
        // Words' `$m.atomBox`, TeX's rule 18 with STIX Two Math's MATH constants.
        var u: CGFloat = base.isChar ? 0 : base.height - k(.superscriptBaselineDropMax, style)
        var v: CGFloat = base.isChar ? 0 : base.depth + k(.subscriptBaselineDropMin, style)
        if let p = supBox {
            u = max(u, k(style.cramped ? .superscriptShiftUpCramped : .superscriptShiftUp, style), p.depth + k(.superscriptBottomMin, style))
        }
        if let b = subBox {
            if supBox == nil {
                v = max(v, k(.subscriptShiftDown, style), b.height - k(.subscriptTopMax, style))
            } else {
                v = max(v, k(.subscriptShiftDown, style))
            }
        }
        if let p = supBox, let b = subBox {
            let gap = (u - p.depth) - (b.height - v)
            let minGap = k(.subSuperscriptGapMin, style)
            if gap < minGap {
                v += minGap - gap
                let psi = k(.superscriptBottomMaxWithSubscript, style) - (u - p.depth)
                if psi > 0 { u += psi; v -= psi }
            }
        }
        var out = MathBox()
        out.add(base, x: 0, y: 0)
        let supX = base.isOp ? base.width : base.width + base.italic, subX = base.isOp ? base.width - base.italic : base.width
        var right = base.width
        if let p = supBox { out.add(p, x: supX, y: u); right = max(right, supX + p.width) }
        if let b = subBox { out.add(b, x: subX, y: -v); right = max(right, subX + b.width) }
        out.width = right + k(.spaceAfterScript, style)
        return out
    }

    /// Limits centered above and below a display operator.
    func limitsBox(_ op: MathBox, sup: [MathNode]?, sub: [MathNode]?, _ style: Style) throws -> MathBox {
        let supBox = try sup.map { try list($0, style.sup) }
        let subBox = try sub.map { try list($0, style.sub) }
        // Words' `$m.atomBox` limits: MATH's limit gaps and baseline rise and drop, nothing added past them.
        let delta = op.italic, w0 = op.width
        let w = max(w0, supBox?.width ?? 0, subBox?.width ?? 0)
        var out = MathBox()
        out.add(op, x: (w - w0) / 2, y: 0)
        if let p = supBox {
            let y = op.height + p.depth + max(k(.upperLimitGapMin, style), k(.upperLimitBaselineRiseMin, style) - p.depth)
            out.add(p, x: (w - p.width) / 2 + delta / 2, y: y)
        }
        if let b = subBox {
            let y = op.depth + b.height + max(k(.lowerLimitGapMin, style), k(.lowerLimitBaselineDropMin, style) - b.height)
            out.add(b, x: (w - b.width) / 2 - delta / 2, y: -y)
        }
        out.width = w
        return out
    }

    /// A base with things stacked over and under it: `\overset`, `\underset`, `\overbrace`, `\underbrace`.
    func stack(_ base: MathBox, over: [MathNode]?, under: [MathNode]?, brace: Unicode.Scalar?, _ style: Style,
               extraSub: [MathNode]? = nil, extraSup: [MathNode]? = nil) throws -> MathBox {
        var core = base
        core.isChar = false
        if let brace {
            let b = try stretch(brace, width: base.width, style)
            let gap = 0.1 * size(style)
            var out = MathBox()
            out.add(base, x: (max(base.width, b.width) - base.width) / 2, y: 0)
            if brace == "\u{23DE}" {
                out.add(b, x: (max(base.width, b.width) - b.width) / 2, y: base.height + gap + b.depth)
            } else {
                out.add(b, x: (max(base.width, b.width) - b.width) / 2, y: -(base.depth + gap + b.height))
            }
            out.width = max(base.width, b.width)
            core = out
        }
        var out = try limitsBox(core, sup: over, sub: under, style)
        if extraSub != nil || extraSup != nil { out = try attach(out, sub: extraSub, sup: extraSup, style) }
        return out
    }

    // MARK: Fractions and radicals

    func fraction(_ num: [MathNode], _ den: [MathNode], rule: Bool, style: Style, left: Unicode.Scalar?, right: Unicode.Scalar?) throws -> MathBox {
        let n = try list(num, style.num), d = try list(den, style.den)
        let display = style.kind == .display
        let axis = k(.axisHeight, style)
        var up: CGFloat, down: CGFloat
        let t = k(.fractionRuleThickness, style)
        if rule {
            up = max(k(display ? .fractionNumeratorDisplayStyleShiftUp : .fractionNumeratorShiftUp, style),
                     axis + t / 2 + k(display ? .fractionNumDisplayStyleGapMin : .fractionNumeratorGapMin, style) + n.depth)
            down = max(k(display ? .fractionDenominatorDisplayStyleShiftDown : .fractionDenominatorShiftDown, style),
                       d.height + k(display ? .fractionDenomDisplayStyleGapMin : .fractionDenominatorGapMin, style) - axis + t / 2)
        } else {
            up = k(display ? .stackTopDisplayStyleShiftUp : .stackTopShiftUp, style)
            down = k(display ? .stackBottomDisplayStyleShiftDown : .stackBottomShiftDown, style)
            let gap = (up - n.depth) - (d.height - down), minGap = k(display ? .stackDisplayStyleGapMin : .stackGapMin, style)
            if gap < minGap { up += (minGap - gap) / 2; down += (minGap - gap) / 2 }
        }
        let w = max(n.width, d.width)
        // KaTeX's `nulldelimiter`: 0.12em on each side of a fraction without delimiters.
        let pad = left == nil ? 0.12 * size(style) : 0
        var out = MathBox()
        out.add(n, x: pad + (w - n.width) / 2, y: up)
        out.add(d, x: pad + (w - d.width) / 2, y: -down)
        if rule { out.rules.append(CGRect(x: pad, y: axis - t / 2, width: w, height: t)) }
        out.width = w + 2 * pad
        guard let left, let right else { return out }
        let total = (display ? 2.39 : 1.01) * size(style)
        let l = try delimiter(left, total: total, style), r = try delimiter(right, total: total, style)
        var wrapped = MathBox()
        wrapped.add(l, x: 0, y: 0)
        wrapped.add(out, x: l.width, y: 0)
        wrapped.add(r, x: l.width + out.width, y: 0)
        wrapped.width = l.width + out.width + r.width
        return wrapped
    }

    /// Words' `$m.sqrt`: a drawn sign (a tick, a heavy down stroke, a long up stroke, then the bar over the body).
    func radical(_ body: [MathNode], index: [MathNode]?, _ style: Style) throws -> MathBox {
        let r = try list(body, style.crampedSelf)
        let t = words(68, style)
        var gap = words(style.kind == .display ? 170 : 85, style)
        let inner = r.height + r.depth + gap + t
        let total = max(inner, words(1100, style))
        gap += (total - inner) / 2
        let sw = words(640, style) + min(total / 12, em * 0.3)
        let h = r.height + gap + t
        var out = MathBox()
        var x: CGFloat = 0
        if let index {
            let i = try list(index, Style(kind: .scriptScript, cramped: true))
            var ix = words(65, style)
            x = ix + i.width - words(335, style)
            if x < 0 { ix -= x; x = 0 }
            out.add(i, x: ix, y: -(total - h) + total * 0.55)
        }
        // Words strokes the sign at 0.068em, at least 0.02 of the formula's em, and the heavy stroke twice that.
        let k = min(total, size(style)), line = max(t, em * 0.02)
        let top = h - line / 2, bottom = -(total - h), w = sw + r.width + words(60, style)
        let thin = CGMutablePath(), heavy = CGMutablePath()
        thin.addLines(between: [CGPoint(x: x + sw / 12, y: bottom + k * 9 / 20), CGPoint(x: x + sw / 5, y: bottom + k * 11 / 20),
                                CGPoint(x: x + sw * 9 / 20, y: bottom), CGPoint(x: x + sw, y: top), CGPoint(x: x + w, y: top)])
        heavy.addLines(between: [CGPoint(x: x + sw / 5, y: bottom + k * 11 / 20), CGPoint(x: x + sw * 9 / 20, y: bottom)])
        out.shapes += [.init(path: thin, stroke: line), .init(path: heavy, stroke: 2 * line)]
        out.add(r, x: x + sw, y: 0)
        out.height = max(out.height, h + words(78, style))
        out.depth = max(out.depth, total - h)
        out.width = x + w
        return out
    }

    // MARK: Delimiters

    /// `\left…\right`: delimiters grown to cover the body around the axis (Words' `$m.fence`, TeX's 901 and 5pt).
    func leftRight(_ l: Unicode.Scalar?, _ body: [MathNode], _ r: Unicode.Scalar?, _ style: Style) throws -> MathBox {
        var inner = try items(body, style)
        let measured = join(inner)
        let axis = words(258, style)
        let reach = max(measured.height - axis, measured.depth + axis)
        let total = max(reach * 1.802, 2 * reach - words(500, style))
        for i in inner.indices {
            if case .middle(let d, let s) = inner[i] { inner[i] = .atom(.rel, try delimiter(d, total: total, s), s) }
        }
        let left = try delimiter(l, total: total, style), right = try delimiter(r, total: total, style)
        // Words lays `\left`, the body and `\right` side by side, with no class spacing between them.
        let body = join(inner)
        var out = MathBox()
        out.add(left, x: 0, y: 0)
        out.add(body, x: left.width, y: 0)
        out.add(right, x: left.width + body.width, y: 0)
        out.width = left.width + body.width + right.width
        return out
    }

    /// Words' `$m.delim`: the glyph itself while it is tall enough, else a drawn shape (or the glyph scaled) `total` tall
    /// and centered on the axis. Nil is the null delimiter.
    func delimiter(_ d: Unicode.Scalar?, total: CGFloat, _ style: Style) throws -> MathBox {
        guard let d else { return MathBox(width: words(120, style)) }
        var glyph = try symbol(d, style)
        glyph.isChar = false
        if total <= glyph.height + glyph.depth + words(20, style) { return glyph }
        let axis = words(258, style), top = total / 2 + axis, bottom = axis - total / 2
        guard let (shape, mirror) = Self.delimiterShapes[d.value] else {
            let f = total / max(glyph.height + glyph.depth, 0.001)
            var out = MathBox()
            out.add(MathBox(glyphs: [.init(glyph: glyph.glyph ?? 0, size: size(style) * f, position: .zero)]),
                    x: 0, y: axis - (glyph.height - glyph.depth) * f / 2)
            out.width = glyph.width * f; out.height = top; out.depth = -bottom
            return out
        }
        // Widths and line weights in thousandths of the formula's em, as Words computes them from the height.
        let n = total / em * 1000, unit = em / 1000
        let w: CGFloat = switch shape {
        case 1: min(420 + n / 20, 750)
        case 2, 7, 8: min(400 + n / 40, 600)
        case 3: min(480 + n / 30, 750)
        case 5: 480
        case 6: min(400 + n / 30, 700)
        case 9, 10: 100 + n / 3
        default: 300
        }
        var out = MathBox(width: words(w, style), height: top, depth: -bottom)
        let line = min(words(45, style) + total / 90, 90 * unit)
        var flip = mirror ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: out.width, ty: 0) : .identity
        out.shapes = Self.delimiterPath(shape, width: out.width, top: top, bottom: bottom, line: line, unit: unit)
            .map { .init(path: $0.path.copy(using: &flip) ?? $0.path, stroke: $0.stroke) }
        return out
    }

    /// Words' delimiter shapes (`$pairs.delim`): the shape, and whether the delimiter is the left one mirrored.
    static let delimiterShapes: [UInt32: (Int, Bool)] = [
        0x28: (1, false), 0x27EE: (1, false), 0x29: (1, true), 0x27EF: (1, true), 0x5B: (2, false), 0x5D: (2, true),
        0x7B: (3, false), 0x7D: (3, true), 0x7C: (4, false), 0x2223: (4, false), 0x2016: (5, false), 0x2225: (5, false),
        0x27E8: (6, false), 0x2329: (6, false), 0x27E9: (6, true), 0x232A: (6, true), 0x230A: (7, false), 0x230B: (7, true),
        0x2308: (8, false), 0x2309: (8, true), 0x2F: (9, false), 0x5C: (10, false),
    ]

    /// One left-hand delimiter shape from Words' `$m.emitPath`, in a box `w` wide from `bottom` to `top` (y up). `unit` is
    /// a thousandth of the formula's em, for the lengths Words doesn't scale.
    static func delimiterPath(_ shape: Int, width w: CGFloat, top: CGFloat, bottom: CGFloat, line t: CGFloat, unit: CGFloat) -> [MathLayout.Shape] {
        let size = top - bottom, mid = (top + bottom) / 2
        let p = CGMutablePath()
        switch shape {
        case 1:
            // Two curves, thick in the middle. A cubic with equal controls reaches 3/4 of the way to them.
            let ax = w - w / 6, k = min(size / 4, w * 2)
            var cx = ax - (ax - w / 5) * 4 / 3
            p.move(to: CGPoint(x: ax, y: top))
            p.addCurve(to: CGPoint(x: ax, y: bottom), control1: CGPoint(x: cx, y: top - k), control2: CGPoint(x: cx, y: bottom + k))
            p.addLine(to: CGPoint(x: ax + t / 4, y: bottom))
            cx += t * 4 / 3
            p.addCurve(to: CGPoint(x: ax + t / 4, y: top), control1: CGPoint(x: cx, y: bottom + k), control2: CGPoint(x: cx, y: top - k))
            p.closeSubpath()
            return [.init(path: p)]
        case 2, 7, 8:
            // A floor has no top arm and a ceiling no bottom arm.
            let ax = w - w / 8, cx = w / 3, k = max(t / 2, 36 * unit), topArm = shape != 7, bottomArm = shape != 8
            p.move(to: CGPoint(x: topArm ? ax : cx, y: top))
            if topArm { p.addLine(to: CGPoint(x: cx, y: top)) }
            p.addLine(to: CGPoint(x: cx, y: bottom))
            if bottomArm { p.addLine(to: CGPoint(x: ax, y: bottom)); p.addLine(to: CGPoint(x: ax, y: bottom + k)) }
            p.addLine(to: CGPoint(x: cx + t, y: bottomArm ? bottom + k : bottom))
            p.addLine(to: CGPoint(x: cx + t, y: topArm ? top - k : top))
            if topArm { p.addLine(to: CGPoint(x: ax, y: top - k)) }
            p.closeSubpath()
            return [.init(path: p)]
        case 3:
            let ax = w - w / 8, cx = w / 2, r = min(ax - cx, size / 6), k = w / 8
            p.move(to: CGPoint(x: ax, y: top))
            p.addQuadCurve(to: CGPoint(x: cx, y: top - r), control: CGPoint(x: cx, y: top))
            p.addLine(to: CGPoint(x: cx, y: mid + r))
            p.addQuadCurve(to: CGPoint(x: k, y: mid), control: CGPoint(x: cx, y: mid))
            p.addQuadCurve(to: CGPoint(x: cx, y: mid - r), control: CGPoint(x: cx, y: mid))
            p.addLine(to: CGPoint(x: cx, y: bottom + r))
            p.addQuadCurve(to: CGPoint(x: ax, y: bottom), control: CGPoint(x: cx, y: bottom))
            return [.init(path: p, stroke: t * 3 / 2)]
        case 4:
            p.addRect(CGRect(x: w / 2 - 25 * unit, y: bottom, width: 50 * unit, height: size))
            return [.init(path: p)]
        case 5:
            p.addRect(CGRect(x: w / 2 - 115 * unit, y: bottom, width: 50 * unit, height: size))
            p.addRect(CGRect(x: w / 2 + 65 * unit, y: bottom, width: 50 * unit, height: size))
            return [.init(path: p)]
        case 6:
            p.addLines(between: [CGPoint(x: w - w / 5, y: top), CGPoint(x: w / 5, y: mid), CGPoint(x: w - w / 5, y: bottom)])
            return [.init(path: p, stroke: t)]
        case 9:
            p.addLines(between: [CGPoint(x: w, y: top), CGPoint(x: 0, y: bottom)])
            return [.init(path: p, stroke: t / 2)]
        default:
            p.addLines(between: [CGPoint(x: 0, y: top), CGPoint(x: w, y: bottom)])
            return [.init(path: p, stroke: t / 2)]
        }
    }

    /// The smallest variant of `s` at least `total` tall, else an assembly of its parts, else the largest variant.
    func vertical(_ s: Unicode.Scalar, total: CGFloat, _ style: Style) throws -> MathBox {
        let g = font.glyph(s)
        guard g != 0 else { throw Unsupported(reason: "no delimiter glyph") }
        let target = total / size(style) * font.unitsPerEm
        guard let c = font.construction(g, vertical: true) else { return glyphBox(g, style) }
        if let v = c.variants.first(where: { $0.advance >= target }) { return glyphBox(v.glyph, style) }
        if !c.parts.isEmpty { return try assemble(c.parts, target: target, vertical: true, style) }
        return glyphBox(c.variants.last?.glyph ?? g, style)
    }

    /// The narrowest horizontal variant of `s` at least `width` wide, else an assembly, else the widest.
    func stretch(_ s: Unicode.Scalar, width: CGFloat, _ style: Style) throws -> MathBox {
        let g = font.glyph(s)
        guard g != 0 else { throw Unsupported(reason: "no stretchy glyph") }
        let target = width / size(style) * font.unitsPerEm
        guard let c = font.construction(g, vertical: false) else { return glyphBox(g, style) }
        if let v = c.variants.first(where: { $0.advance >= target }) { return glyphBox(v.glyph, style) }
        if !c.parts.isEmpty { return try assemble(c.parts, target: target, vertical: false, style) }
        return glyphBox(c.variants.last?.glyph ?? g, style)
    }

    /// Glues a glyph assembly to `target` font units: extenders repeat until the parts can reach it, then the joints
    /// share the overlap (OpenType MATH, GlyphAssembly).
    func assemble(_ parts: [MathFont.Part], target: CGFloat, vertical: Bool, _ style: Style) throws -> MathBox {
        let minOverlap = font.minConnectorOverlap
        var sequence: [MathFont.Part] = []
        var reached = false
        for repeats in 1...200 {
            sequence = parts.flatMap { $0.extender ? Array(repeating: $0, count: repeats) : [$0] }
            let full = sequence.reduce(0) { $0 + $1.fullAdvance }
            if full - CGFloat(sequence.count - 1) * minOverlap >= target { reached = true; break }
        }
        // A delimiter that can't grow tall enough would sit short of its contents; show the source instead.
        guard reached else { throw Unsupported(reason: "delimiter too tall") }
        let full = sequence.reduce(0) { $0 + $1.fullAdvance }
        let joints = CGFloat(max(1, sequence.count - 1))
        var overlap = max(minOverlap, (full - target) / joints)
        let maxOverlap = zip(sequence, sequence.dropFirst()).map { min($0.endConnector, $1.startConnector) }.min() ?? minOverlap
        overlap = min(overlap, max(minOverlap, maxOverlap))
        let scale = size(style) / font.unitsPerEm
        var out = MathBox()
        var pos: CGFloat = 0
        for (i, part) in sequence.enumerated() {
            let box = glyphBox(part.glyph, style)
            if vertical { out.add(box, x: 0, y: pos * scale) } else { out.add(box, x: pos * scale, y: 0) }
            out.width = max(out.width, vertical ? box.width : 0)
            pos += part.fullAdvance - (i < sequence.count - 1 ? overlap : 0)
        }
        if vertical {
            // Parts stand on the baseline from the bottom up; the caller centers the stack on the axis.
            out.depth = max(0, out.depth)
        } else {
            out.width = pos * scale
        }
        out.isChar = false
        return out
    }

    /// `\xrightarrow[below]{above}` (KaTeX's xArrow.ts): labels in script style, the arrow stretched 0.5em past the wider
    /// one on each side and at least as wide as `\longrightarrow`, centered on the axis with 0.111em gaps.
    func xArrow(_ arrow: Unicode.Scalar, above: [MathNode], below: [MathNode]?, _ style: Style) throws -> MathBox {
        let top = try list(above, style.sup), bottom = try below.map { try list($0, style.sub) }
        let em = size(style)
        let width = max(max(top.width, bottom?.width ?? 0) + em, 1.6 * em)
        let shaft = try stretch(arrow, width: width, style)
        let w = max(width, shaft.width)
        let axis = k(.axisHeight, style)
        let centred = shaft.shifted(up: axis - (shaft.height - shaft.depth) / 2)
        var out = MathBox()
        out.add(centred, x: (w - shaft.width) / 2, y: 0)
        let gap = 0.111 * em
        // KaTeX lifts the label by its depth only past 0.25em, so a `g` keeps its descender near the arrow.
        out.add(top, x: (w - top.width) / 2, y: centred.height + gap + (top.depth > 0.25 * em ? top.depth : 0))
        if let bottom { out.add(bottom, x: (w - bottom.width) / 2, y: -(centred.depth + gap + bottom.height)) }
        out.width = w
        return out
    }

    // MARK: Accents

    func accent(_ a: Unicode.Scalar, _ body: [MathNode], stretchy: Bool, _ style: Style) throws -> MathBox {
        let base = try list(body, style.crampedSelf)
        let arrow = ["\u{2192}", "\u{2190}", "\u{2194}"].contains(a)
        var mark: MathBox
        if stretchy {
            mark = try stretch(a, width: base.width, style)
        } else {
            mark = try symbol(a, style)
        }
        let scale = size(style) / font.unitsPerEm
        let markAttach: CGFloat = mark.glyph.flatMap { g in font.topAccent(g).map { $0 * scale } }
            ?? (mark.glyphs.count == 1 ? glyphCenter(mark) : mark.width / 2)
        let baseAttach: CGFloat = (base.isChar ? base.glyph.flatMap { g in font.topAccent(g).map { $0 * scale } } : nil)
            ?? base.width / 2
        var out = MathBox()
        out.add(base, x: 0, y: 0)
        let y: CGFloat
        if arrow {
            y = base.height + 0.08 * size(style) + mark.depth
        } else {
            y = base.height - min(base.height, k(.accentBaseHeight, style))
        }
        out.add(mark, x: baseAttach - markAttach, y: y)
        out.width = base.width
        out.depth = base.depth
        out.isChar = false
        out.italic = base.italic
        return out
    }

    private func glyphCenter(_ b: MathBox) -> CGFloat {
        guard let g = b.glyph else { return b.width / 2 }
        let m = font.metrics(g), scale = b.glyphs[0].size / font.unitsPerEm
        return m.bounds.midX * scale
    }

    // MARK: Text

    /// Words' `$m.textNode`: the box is the run's metrics from the table, a space a third of an em. Chromium draws the run
    /// as one `<text>`, so the glyphs sit at the font's own advances.
    func text(_ s: String, _ variant: TeXParser.Variant, _ style: Style) throws -> MathBox {
        var out = MathBox()
        var x: CGFloat = 0, width: CGFloat = 0
        let scale = size(style) / font.unitsPerEm
        for scalar in s.unicodeScalars {
            if scalar == " " || scalar == "\u{A0}" { x += words(333, style); width += words(333, style); continue }
            if scalar == "\u{2009}" { x += size(style) / 6; width += size(style) / 6; continue }
            let mapped = variant == .roman ? scalar : (TeXParser.letter(scalar, variant) ?? scalar)
            let g = font.glyph(mapped)
            guard g != 0 else { throw Unsupported(reason: "no glyph for text") }
            let box = glyphBox(g, style)
            out.add(box, x: x, y: 0)
            x += font.metrics(g).advance * scale
            width += box.width
        }
        out.width = width
        return out
    }

    // MARK: Arrays

    func array(_ rows: [[[MathNode]]], columns spec: [Character], kind: TeXParser.ArrayKind, gaps: [CGFloat], hlines: [Int] = [],
               _ style: Style) throws -> MathBox {
        guard !rows.isEmpty else { return MathBox() }
        // `|` in `array`'s spec: a rule before the column it precedes, at `columns.count` after the last.
        let columns = spec.filter { $0 != "|" }
        var vlines: [Int] = []
        var seen = 0
        for ch in spec { if ch == "|" { vlines.append(seen) } else { seen += 1 } }
        let cellStyle: Style
        switch kind {
        case .aligned, .alignedAt, .gathered: cellStyle = Style(kind: .display, cramped: style.cramped)
        case .substack: cellStyle = style
        case .smallMatrix: cellStyle = Style(kind: .script, cramped: style.cramped)
        case .matrix, .cases, .array: cellStyle = Style(kind: style.kind == .display ? .text : style.kind, cramped: style.cramped)
        }
        let stretch: CGFloat = kind == .cases ? 1.2 : kind == .substack || kind == .smallMatrix ? 0.5 : 1
        let skip = 1.2 * stretch * size(style)
        let jot: CGFloat = kind == .aligned || kind == .alignedAt || kind == .gathered ? 0.3 * size(style) : 0
        let columnCount = rows.map(\.count).max() ?? 0
        var cells: [[MathBox]] = []
        for row in rows {
            var line: [MathBox] = []
            for (c, cell) in row.enumerated() {
                // `aligned` starts each right-hand column with `{}` so `&= b` spaces its relation.
                let nodes = (kind == .aligned || kind == .alignedAt) && c % 2 == 1 ? [MathNode.group([], .ord)] + cell : cell
                line.append(try list(nodes, cellStyle))
            }
            cells.append(line)
        }
        func align(_ c: Int) -> Character {
            switch kind {
            case .aligned, .alignedAt: c % 2 == 0 ? "r" : "l"
            case .cases: "l"
            case .gathered, .substack, .matrix, .smallMatrix: "c"
            case .array: c < columns.count ? columns[c] : "c"
            }
        }
        var widths = [CGFloat](repeating: 0, count: columnCount)
        for line in cells { for (c, b) in line.enumerated() { widths[c] = max(widths[c], b.width) } }
        let colsep: CGFloat = 0.5 * size(style)
        func gap(before c: Int) -> CGFloat {
            guard c > 0 else { return kind == .array ? colsep : 0 }
            switch kind {
            case .aligned: return c % 2 == 0 ? size(style) : 0
            case .alignedAt, .gathered, .substack: return 0
            case .cases: return size(style)
            // KaTeX's "small" column separation: 0.2778em at script size.
            case .smallMatrix: return 2 * 0.2778 * size(Style(kind: .script))
            case .matrix, .array: return 2 * colsep
            }
        }
        var x: [CGFloat] = []
        var cursor: CGFloat = 0
        for c in 0..<columnCount { cursor += gap(before: c); x.append(cursor); cursor += widths[c] }
        let totalWidth = cursor + (kind == .array ? colsep : 0)
        var out = MathBox()
        var y: CGFloat = 0
        var rowBottoms: [CGFloat] = []
        var placed: [(MathBox, CGFloat, CGFloat)] = []
        for (r, line) in cells.enumerated() {
            let h = max(line.map(\.height).max() ?? 0, 0.7 * skip)
            var d = max(line.map(\.depth).max() ?? 0, 0.3 * skip)
            // `\\[dim]` (KaTeX array.ts): a positive gap deepens the row past its strut, a negative one pulls the next row up.
            let gap = r < gaps.count ? gaps[r] * em : 0
            if gap > 0 { d = max(d, gap + 0.3 * skip) }
            y -= h
            for (c, b) in line.enumerated() {
                let a = align(c)
                let dx = a == "l" ? 0 : a == "r" ? widths[c] - b.width : (widths[c] - b.width) / 2
                placed.append((b, x[c] + dx, y))
            }
            y -= d + (r < cells.count - 1 ? jot : 0) + min(0, gap)
            rowBottoms.append(-y)
        }
        let total = -y
        let shift = total / 2 + k(.axisHeight, style)
        for (b, bx, by) in placed { out.add(b, x: bx, y: by + shift) }
        // `\arrayrulewidth` is 0.04em: rules between columns sit in the middle of their gap, rules between rows on the boundary.
        let rule = 0.04 * size(style)
        for v in vlines {
            let lx = v == 0 ? 0 : v >= columnCount ? totalWidth - rule : x[v] - gap(before: v) / 2 - rule / 2
            out.rules.append(CGRect(x: lx, y: shift - total, width: rule, height: total))
        }
        for h in hlines {
            // Distance from the top: 0 above the first row, the bottom of row h - 1 below it, kept inside the box at the edges.
            let down = h == 0 ? 0 : rowBottoms[min(h, rowBottoms.count) - 1]
            let ly = min(shift - rule, max(shift - total, shift - down - rule / 2))
            out.rules.append(CGRect(x: 0, y: ly, width: totalWidth, height: rule))
        }
        out.height = shift
        out.depth = total - shift
        out.width = totalWidth
        return out
    }
}

/// Typesets and caches formulas for message text.
enum MathRenderer {
    /// KaTeX sets formulas at 1.21em of the surrounding text (`.katex { font-size: 1.21em }`).
    static let scale: CGFloat = 1.21

    nonisolated(unsafe) private static var cache: [String: MathLayout?] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    private static let lock = NSLock()

    /// The layout of `tex`, nil when stage 1 can't typeset it and the source shows instead.
    // ponytail: FIFO of 1,000 layouts like T3's typeset cache; key on width too if layouts ever depend on it
    static func layout(_ tex: String, display: Bool, textSize: CGFloat) -> MathLayout? {
        let key = "\(display ? "d" : "i")\(textSize):\(tex)"
        if let hit = lock.withLock({ cache[key] }) { return hit }
        func typeset(_ tex: String) -> MathLayout? {
            guard let font = MathFont.shared, let nodes = try? TeXParser.parse(tex.trimmingCharacters(in: .whitespacesAndNewlines)),
                  !nodes.isEmpty, let (box, tag) = try? MathTypesetter.layout(nodes, display: display, em: textSize * scale, font: font),
                  box.width.isFinite, box.height.isFinite, box.depth.isFinite, box.width < 20_000 else { return nil }
            return MathLayout(box, tag: tag)
        }
        // TeX that fails only because a `%` after text started a comment, as in `\text{3.18% yield}`, gets one more try
        // with those escaped (MathTypeset.tsx at 4928, #29511).
        let result = typeset(tex) ?? {
            let repaired = escapeLiteralPercents(tex)
            return repaired == tex ? nil : typeset(repaired)
        }()
        lock.withLock {
            if cache.updateValue(result, forKey: key) == nil { order.append(key) }
            if order.count > 1_000 { cache[order.removeFirst()] = nil }
        }
        return result
    }
}

/// `escapeLiteralPercents` (MathTypeset.logic.ts at 4928): escapes each `%` written right after other text. A `%` at a
/// line start or after whitespace stays a comment. Skips escapes and `\verb` as KaTeX's lexer does, in one pass.
func escapeLiteralPercents(_ tex: String) -> String {
    let c = Array(tex)
    var out = ""
    var copied = 0, i = 0
    while i < c.count {
        let ch = c[i]
        if ch == "\\" {
            if i + 5 <= c.count, String(c[i..<(i + 5)]) == "\\verb" {
                let starred = i + 5 < c.count && c[i + 5] == "*"
                let at = i + (starred ? 6 : 5)
                if at < c.count, starred || !(c[at] == "*" || (c[at].isASCII && c[at].isLetter)) {
                    let delimiter = c[at]
                    var close = at + 1
                    while close < c.count, c[close] != delimiter, c[close] != "\n", c[close] != "\r" { close += 1 }
                    // KaTeX rejects a \verb that does not close on its own line.
                    guard close < c.count, c[close] == delimiter else { return tex }
                    i = close + 1
                    continue
                }
            }
            // A control symbol such as `\%` or `\\` is two characters.
            i += 2
        } else if ch == "%", i > 0, !c[i - 1].isWhitespace {
            out += String(c[copied..<i]) + "\\%"
            i += 1
            copied = i
        } else if ch == "%" {
            while i < c.count, c[i] != "\n" { i += 1 }
            i += 1
        } else {
            i += 1
        }
    }
    return copied == 0 ? tex : out + String(c[copied...])
}
