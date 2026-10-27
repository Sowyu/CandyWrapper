import AppKit
import CoreText

/// A typeset formula: glyphs, rules and strokes around a baseline at the origin, y up. Width, height above the baseline
/// and depth below it follow KaTeX's box model. Parts with no color of their own take the text color.
final class MathLayout: @unchecked Sendable {
    struct Glyph { let glyph: CGGlyph; let size: CGFloat; let position: CGPoint; var color: CGColor? = nil }
    struct Stroke { let from: CGPoint; let to: CGPoint; let width: CGFloat; var color: CGColor? = nil }
    let width: CGFloat
    let height: CGFloat
    let depth: CGFloat
    let glyphs: [Glyph]
    let rules: [CGRect]
    let ruleColors: [CGColor?]
    let strokes: [Stroke]
    /// A display formula's `\tag`, drawn at the column's right edge on the formula's baseline.
    let tag: MathLayout?

    init(_ box: MathBox, tag: MathBox? = nil) {
        width = box.width; height = box.height; depth = box.depth
        glyphs = box.glyphs; rules = box.rules; ruleColors = box.ruleColors; strokes = box.strokes
        self.tag = tag.map { MathLayout($0) }
    }

    /// Draws with the baseline's left end at `origin`, in a flipped (y down) context.
    func draw(in ctx: CGContext, at origin: CGPoint, color: CGColor) {
        guard let font = MathFont.shared else { return }
        // Rules snap to device pixels, as Blink snaps KaTeX's borders: a fraction bar stays one crisp line.
        let scale = max(1, abs(ctx.userSpaceToDeviceSpaceTransform.d))
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: 1, y: -1)
        for (i, r) in rules.enumerated() {
            ctx.setFillColor((i < ruleColors.count ? ruleColors[i] : nil) ?? color)
            let h = max(1 / scale, (r.height * scale).rounded() / scale)
            ctx.fill(CGRect(x: r.minX, y: (r.minY * scale).rounded() / scale, width: r.width, height: h))
        }
        ctx.textMatrix = .identity
        var start = 0
        while start < glyphs.count {
            let size = glyphs[start].size, tint = glyphs[start].color
            var end = start
            while end < glyphs.count, glyphs[end].size == size, glyphs[end].color == tint { end += 1 }
            ctx.setFillColor(tint ?? color)
            var ids = glyphs[start..<end].map(\.glyph), points = glyphs[start..<end].map(\.position)
            CTFontDrawGlyphs(font.font(size: size), &ids, &points, ids.count, ctx)
            start = end
        }
        // Over the glyphs, as KaTeX paints `\cancel`.
        for s in strokes {
            ctx.setStrokeColor(s.color ?? color)
            ctx.setLineWidth(s.width)
            ctx.strokeLineSegments(between: [s.from, s.to])
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
    var strokes: [MathLayout.Stroke] = []
    /// A lone symbol's italic correction, included in `width`.
    var italic: CGFloat = 0
    /// A lone symbol: scripts sit at the font's shifts instead of hanging off the box (TeX rule 18a).
    var isChar = false
    /// The glyph of a lone symbol, for accent attachment.
    var glyph: CGGlyph?

    mutating func add(_ b: MathBox, x: CGFloat, y: CGFloat) {
        glyphs += b.glyphs.map { .init(glyph: $0.glyph, size: $0.size, position: CGPoint(x: $0.position.x + x, y: $0.position.y + y), color: $0.color) }
        ruleColors += Array(repeating: nil, count: max(0, rules.count - ruleColors.count))
        ruleColors += (0..<b.rules.count).map { $0 < b.ruleColors.count ? b.ruleColors[$0] : nil }
        rules += b.rules.map { $0.offsetBy(dx: x, dy: y) }
        strokes += b.strokes.map { .init(from: CGPoint(x: $0.from.x + x, y: $0.from.y + y), to: CGPoint(x: $0.to.x + x, y: $0.to.y + y),
                                          width: $0.width, color: $0.color) }
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
        out.strokes = strokes.map { var s = $0; if s.color == nil { s.color = color }; return s }
        return out
    }
}

/// Lays out `MathNode`s with the TeXbook's Appendix G rules, reading the constants from the font's MATH table.
/// KaTeX follows the same rules with Computer Modern's parameters, which Latin Modern Math carries.
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
                        x += CGFloat([0, 3, 4, 5][abs(code)]) * size(style) / 18
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
            if up { out.strokes.append(.init(from: CGPoint(x: 0, y: bottom), to: CGPoint(x: out.width, y: top), width: w)) }
            if down { out.strokes.append(.init(from: CGPoint(x: 0, y: top), to: CGPoint(x: out.width, y: bottom), width: w)) }
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
        let m = font.metrics(g), s = size(style)
        let scale = s / font.unitsPerEm
        let italic = font.italic(g) * scale
        return MathBox(width: m.advance * scale + italic, height: max(0, m.bounds.maxY * scale), depth: max(0, -m.bounds.minY * scale),
                       glyphs: [.init(glyph: g, size: s, position: .zero)], italic: italic, isChar: true, glyph: g)
    }

    func symbol(_ s: Unicode.Scalar, _ style: Style) throws -> MathBox {
        let g = font.glyph(s)
        guard g != 0 else { throw Unsupported(reason: "no glyph for U+\(String(s.value, radix: 16))") }
        return glyphBox(g, style)
    }

    /// A big operator, centered on the math axis, with its display size in display style.
    func largeOp(_ s: Unicode.Scalar, _ style: Style, limits: Bool?) throws -> (box: MathBox, limits: Bool) {
        var g = font.glyph(s)
        guard g != 0 else { throw Unsupported(reason: "no operator glyph") }
        if style.kind == .display, let c = font.construction(g, vertical: true) {
            let min = font.constants[.displayOperatorMinHeight] ?? 0
            g = (c.variants.first { $0.advance >= min } ?? c.variants.last)?.glyph ?? g
        }
        var box = glyphBox(g, style)
        // KaTeX's op.ts: an operator's width leaves out its italic correction; scripts use it instead (sup at the edge,
        // sub pulled back by it), so `\int_a^b` hugs the glyph.
        box.width -= box.italic
        let shift = (box.height - box.depth) / 2 - k(.axisHeight, style)
        var out = box.shifted(up: -shift)
        out.isChar = false
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
        // KaTeX's supsub.ts with Computer Modern's sigma values (fontMetricsData): sup_drop 0.386 and sub_drop 0.05 of the
        // script's size, sup1/sup2/sup3 0.413/0.363/0.289, sub1/sub2 0.15/0.247. The MATH table merges some of these.
        var u: CGFloat = base.isChar ? 0 : base.height - 0.386 * size(style.sup)
        var v: CGFloat = base.isChar ? 0 : base.depth + 0.05 * size(style.sub)
        let supShift = (style.cramped ? 0.289 : style.kind == .display ? 0.413 : 0.363) * size(style)
        if let p = supBox {
            u = max(u, supShift, p.depth + k(.superscriptBottomMin, style))
        }
        if let b = subBox {
            if supBox == nil {
                v = max(v, 0.15 * size(style), b.height - k(.subscriptTopMax, style))
            } else {
                v = max(v, 0.247 * size(style))
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
        let supX = base.width, subX = base.width - base.italic
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
        let delta = op.italic, w0 = op.width
        let w = max(w0, supBox?.width ?? 0, subBox?.width ?? 0)
        // KaTeX's bigOpSpacing1 to 5 (Computer Modern's xi9 to xi13): 0.111, 0.166, 0.2, 0.6 and 0.1em.
        let em = size(style), extra = 0.1 * em
        var out = MathBox()
        out.add(op, x: (w - w0) / 2, y: 0)
        if let p = supBox {
            let y = op.height + max(0.111 * em, 0.2 * em - p.depth) + p.depth
            out.add(p, x: (w - p.width) / 2 + delta / 2, y: y)
            out.height = y + p.height + extra
        }
        if let b = subBox {
            let y = op.depth + max(0.166 * em, 0.6 * em - b.height) + b.height
            out.add(b, x: (w - b.width) / 2 - delta / 2, y: -y)
            out.depth = y + b.depth + extra
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

    func radical(_ body: [MathNode], index: [MathNode]?, _ style: Style) throws -> MathBox {
        let r = try list(body, style.crampedSelf)
        let t = k(.radicalRuleThickness, style)
        var gap = k(style.kind == .display ? .radicalDisplayStyleVerticalGap : .radicalVerticalGap, style)
        let need = r.height + r.depth + gap + t
        let surd = try vertical("\u{221A}", total: need, style)
        let total = surd.height + surd.depth
        if total > need { gap += (total - need) / 2 }
        let top = r.height + gap + t
        var out = MathBox()
        var x: CGFloat = 0
        if let index {
            let i = try list(index, Style(kind: .scriptScript, cramped: true))
            let before = k(.radicalKernBeforeDegree, style), after = k(.radicalKernAfterDegree, style)
            let raise = (font.constants[.radicalDegreeBottomRaisePercent] ?? 60) / 100 * total
            out.add(i, x: before, y: top - total + raise)
            x = max(0, before + i.width + after)
        }
        let glyph = surd.shifted(up: top - surd.height)
        out.add(glyph, x: x, y: 0)
        let bodyX = x + glyph.width
        out.add(r, x: bodyX, y: 0)
        out.rules.append(CGRect(x: bodyX, y: top - t, width: r.width, height: t))
        out.height = max(out.height, top + k(.radicalExtraAscender, style))
        out.width = bodyX + r.width
        return out
    }

    // MARK: Delimiters

    /// `\left…\right`: delimiters grown to cover the body around the axis (TeX's \delimiterfactor 901, \delimitershortfall 5pt).
    func leftRight(_ l: Unicode.Scalar?, _ body: [MathNode], _ r: Unicode.Scalar?, _ style: Style) throws -> MathBox {
        var inner = try items(body, style)
        let measured = join(inner)
        let axis = k(.axisHeight, style)
        let reach = max(measured.height - axis, measured.depth + axis)
        let total = max(reach * 2 * 0.901, 2 * reach - 0.5 * size(style))
        for i in inner.indices {
            if case .middle(let d, let s) = inner[i] { inner[i] = .atom(.rel, try delimiter(d, total: total, s), s) }
        }
        let left = try delimiter(l, total: total, style), right = try delimiter(r, total: total, style)
        return join([.atom(.open, left, style)] + inner + [.atom(.close, right, style)])
    }

    /// A delimiter at least `total` tall, centered on the axis; nil is the null delimiter.
    func delimiter(_ d: Unicode.Scalar?, total: CGFloat, _ style: Style) throws -> MathBox {
        guard let d else { return MathBox(width: 0.12 * size(style)) }
        let box = try vertical(d, total: total, style)
        let shift = (box.height - box.depth) / 2 - k(.axisHeight, style)
        var out = box.shifted(up: -shift)
        out.isChar = false
        return out
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
            out.width = max(out.width, vertical ? box.width - box.italic : 0)
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
            mark = try stretch(a, width: base.width - (arrow ? 0 : base.italic), style)
        } else {
            mark = try symbol(a, style)
        }
        let scale = size(style) / font.unitsPerEm
        let markAttach: CGFloat = mark.glyph.flatMap { g in font.topAccent(g).map { $0 * scale } }
            ?? (mark.glyphs.count == 1 ? glyphCenter(mark) : mark.width / 2)
        let baseAttach: CGFloat = (base.isChar ? base.glyph.flatMap { g in font.topAccent(g).map { $0 * scale } } : nil)
            ?? (base.width - base.italic) / 2
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

    func text(_ s: String, _ variant: TeXParser.Variant, _ style: Style) throws -> MathBox {
        var out = MathBox()
        var x: CGFloat = 0
        for scalar in s.unicodeScalars {
            if scalar == " " || scalar == "\u{A0}" { x += 0.25 * size(style); continue }
            if scalar == "\u{2009}" { x += size(style) / 6; continue }
            let mapped = variant == .roman ? scalar : (TeXParser.letter(scalar, variant) ?? scalar)
            let g = font.glyph(mapped)
            guard g != 0 else { throw Unsupported(reason: "no glyph for text") }
            var box = glyphBox(g, style)
            box.width -= box.italic
            out.add(box, x: x, y: 0)
            x += box.width
        }
        out.width = x
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
        let result: MathLayout? = {
            guard let font = MathFont.shared, let nodes = try? TeXParser.parse(tex.trimmingCharacters(in: .whitespacesAndNewlines)),
                  !nodes.isEmpty, let (box, tag) = try? MathTypesetter.layout(nodes, display: display, em: textSize * scale, font: font),
                  box.width.isFinite, box.height.isFinite, box.depth.isFinite, box.width < 20_000 else { return nil }
            return MathLayout(box, tag: tag)
        }()
        lock.withLock {
            if cache.updateValue(result, forKey: key) == nil { order.append(key) }
            if order.count > 1_000 { cache[order.removeFirst()] = nil }
        }
        return result
    }
}
