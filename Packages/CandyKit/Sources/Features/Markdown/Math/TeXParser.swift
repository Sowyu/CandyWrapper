import Foundation

/// TeX atom classes, which decide the spacing between neighbours (TeXbook ch. 18, KaTeX's `mord`, `mbin`…).
enum MathClass: Int, Sendable { case ord, op, bin, rel, open, close, punct, inner }

enum MathStyleKind: Sendable { case display, text, script, scriptScript }

/// One parsed formula. Letters already carry their final codepoint (`x` is U+1D465, `\mathbb{R}` is ℝ).
indirect enum MathNode: Sendable {
    case symbol(Unicode.Scalar, MathClass)
    /// `\sum`, `\int`: a glyph that grows in display style. `limits` nil keeps the default (limits for all but integrals).
    case largeOp(Unicode.Scalar, limits: Bool?)
    /// `\sin`, `\lim`, `\operatorname{…}`: upright text with operator spacing.
    case namedOp(String, limits: Bool)
    case group([MathNode], MathClass)
    case scripts(MathNode, sub: [MathNode]?, sup: [MathNode]?)
    case frac(num: [MathNode], den: [MathNode], rule: Bool, style: MathStyleKind?, left: Unicode.Scalar?, right: Unicode.Scalar?)
    case sqrt([MathNode], index: [MathNode]?)
    /// `\left…\right`; a nil delimiter is `.`. `\middle` delimiters sit in the body as `.middle`.
    case leftRight(left: Unicode.Scalar?, body: [MathNode], right: Unicode.Scalar?)
    case middle(Unicode.Scalar?)
    /// `\big` and friends: size 1 to 4.
    case sizedDelim(Unicode.Scalar, size: Int, MathClass)
    case accent(Unicode.Scalar, [MathNode], stretchy: Bool)
    case overline([MathNode])
    case underline([MathNode])
    /// `\overset`, `\underset`, `\stackrel`, `\overbrace`, `\underbrace`: limits around a base, with an optional brace.
    case overUnder(base: [MathNode], over: [MathNode]?, under: [MathNode]?, brace: Unicode.Scalar?, MathClass)
    case text(String, TeXParser.Variant)
    /// Horizontal space in em of the current size, or in mu when `mu`.
    case space(CGFloat, mu: Bool)
    case style(MathStyleKind)
    /// `gaps[i]`: the extra space `\\[dim]` asks for after row i, in em. `hlines` holds the row boundaries with an `\hline`
    /// (0 above the first row, `rows.count` below the last); `columns` may hold `|` between letters.
    case array(rows: [[[MathNode]]], columns: [Character], kind: TeXParser.ArrayKind, gaps: [CGFloat], hlines: [Int] = [])
    /// `\color` and `\textcolor`: the body in this color, keeping its spacing.
    case colored(MathColor, [MathNode])
    /// `\cancel` (`/`), `\bcancel` (`\`) and `\xcancel` (both).
    case cancel([MathNode], up: Bool, down: Bool)
    /// `\xrightarrow[below]{above}` and `\xleftarrow`: an arrow stretched under and over its labels.
    case xArrow(Unicode.Scalar, above: [MathNode], below: [MathNode]?)
    /// `\tag{…}`: a display formula's label at the column's right edge. Only the top level of a display formula holds one.
    case tag(String)
    case phantom([MathNode], width: Bool, height: Bool)
    case boxed([MathNode])
}

/// Parses the TeX subset that stage 1 typesets into `MathNode`s. Anything else throws, and the formula shows its source.
struct TeXParser {
    struct Unsupported: Error { let reason: String }

    enum Variant: Sendable { case normal, roman, italic, bold, boldItalic, blackboard, calligraphic, fraktur, sans, mono }
    enum ArrayKind: Sendable { case matrix, smallMatrix, cases, aligned, alignedAt, gathered, array, substack }

    private let tokens: [Token]
    private var at = 0
    private var depth = 0
    private var tags = 0

    enum Token: Equatable { case command(String), char(Character), begin, end, sup, sub, align, eof }

    static func parse(_ tex: String) throws -> [MathNode] {
        let tokens = tokenize(tex)
        // A budget like KaTeX's maxExpand: huge or pathological input shows as source instead of costing the main thread.
        guard tokens.count <= 5_000 else { throw Unsupported(reason: "too long") }
        var p = TeXParser(tokens: tokens)
        let list = try p.list(variant: .normal, until: [.eof])
        guard p.tags <= 1 else { throw Unsupported(reason: "several tags") }
        return list
    }

    private init(tokens: [Token]) { self.tokens = tokens }

    // MARK: Tokens

    static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        let c = Array(s)
        var i = 0
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "\\":
                i += 1
                guard i < c.count else { out.append(.char("\\")); break }
                if c[i].isLetter, c[i].isASCII {
                    var name = ""
                    while i < c.count, c[i].isLetter, c[i].isASCII { name.append(c[i]); i += 1 }
                    // `\operatorname*`: the star belongs to the name.
                    if (name == "operatorname" || name == "align" || name == "gather"), i < c.count, c[i] == "*" { name += "*"; i += 1 }
                    out.append(.command(name))
                    continue
                }
                out.append(.command(String(c[i])))
            case "{": out.append(.begin)
            case "}": out.append(.end)
            case "^": out.append(.sup)
            case "_": out.append(.sub)
            case "&": out.append(.align)
            case "%":
                while i < c.count, c[i] != "\n" { i += 1 }
            default:
                out.append(.char(ch))
            }
            i += 1
        }
        out.append(.eof)
        return out
    }

    private var peek: Token { tokens[at] }
    private mutating func next() -> Token { let t = tokens[at]; if at < tokens.count - 1 { at += 1 }; return t }
    private mutating func skipSpaces() { while case .char(let c) = peek, c.isWhitespace { _ = next() } }

    // MARK: Lists

    /// Parses atoms until one of `until` (left unconsumed). `variant` styles letters (`\mathbf` and friends).
    private mutating func list(variant start: Variant, until: [Token]) throws -> [MathNode] {
        depth += 1
        defer { depth -= 1 }
        guard depth < 100 else { throw Unsupported(reason: "nesting") }
        var out: [MathNode] = []
        var variant = start
        while true {
            skipSpaces()
            let t = peek
            if until.contains(t) { return out }
            switch t {
            case .eof: throw Unsupported(reason: "unclosed group")
            case .end: throw Unsupported(reason: "unbalanced }")
            case .align, .command("\\"), .command("cr"):
                throw Unsupported(reason: "& or \\\\ outside an environment")
            case .sup, .sub:
                _ = next()
                try attachScript(t == .sup, to: &out, variant: variant)
            case .char("'"):
                // Primes are superscripts: x'' is x^{\prime\prime}.
                var primes = 0
                while case .char("'") = peek { _ = next(); primes += 1 }
                let glyph: Unicode.Scalar = primes == 1 ? "\u{2032}" : primes == 2 ? "\u{2033}" : primes == 3 ? "\u{2034}" : "\u{2057}"
                let sup = [MathNode.symbol(glyph, .ord)]
                var extra: [MathNode] = []
                if case .sup = peek {
                    _ = next()
                    extra = try argument(variant: variant)
                }
                try attach(sup: sup + extra, to: &out)
            case .command("color"):
                // `{\color{red} a + b}`: the rest of the group.
                _ = next()
                let color = try MathColor(try rawArgument())
                out.append(.colored(color, try list(variant: variant, until: until)))
                return out
            case .command(let n) where Self.switches[n] != nil:
                // `{\rm d}`: the old switches restyle the rest of the group.
                _ = next()
                variant = Self.switches[n]!
            default:
                out += try atom(variant: variant)
            }
        }
    }

    private static let switches: [String: Variant] = ["rm": .roman, "bf": .bold, "it": .italic, "cal": .calligraphic, "sf": .sans, "tt": .mono]

    private mutating func attachScript(_ isSup: Bool, to out: inout [MathNode], variant: Variant) throws {
        let arg = try argument(variant: variant)
        if isSup { try attach(sup: arg, to: &out) } else { try attach(sub: arg, to: &out) }
    }

    private func base(of out: inout [MathNode]) -> (MathNode, [MathNode]?, [MathNode]?) {
        guard let last = out.popLast() else { return (.group([], .ord), nil, nil) }
        if case .scripts(let b, let sub, let sup) = last { return (b, sub, sup) }
        return (last, nil, nil)
    }

    private func attach(sup: [MathNode], to out: inout [MathNode]) throws {
        let (b, sub, old) = base(of: &out)
        if let old {
            // Only primes may meet a second superscript: x'^2.
            guard old.allSatisfy({ if case .symbol(let s, _) = $0 { return (0x2032...0x2057).contains(s.value) }; return false }) else {
                throw Unsupported(reason: "double superscript")
            }
            out.append(.scripts(b, sub: sub, sup: old + sup))
            return
        }
        out.append(.scripts(b, sub: sub, sup: sup))
    }

    private func attach(sub: [MathNode], to out: inout [MathNode]) throws {
        let (b, old, sup) = base(of: &out)
        if old != nil { throw Unsupported(reason: "double subscript") }
        out.append(.scripts(b, sub: sub, sup: sup))
    }

    /// A macro argument: a braced group or one token.
    private mutating func argument(variant: Variant) throws -> [MathNode] {
        skipSpaces()
        switch peek {
        case .begin:
            _ = next()
            let inner = try list(variant: variant, until: [.end])
            _ = next()
            return inner
        case .eof, .end, .align, .sup, .sub:
            throw Unsupported(reason: "missing argument")
        default:
            return try atom(variant: variant)
        }
    }

    /// `[…]` after a command, as raw tokens parsed as math.
    private mutating func optionalArgument(variant: Variant) throws -> [MathNode]? {
        skipSpaces()
        guard case .char("[") = peek else { return nil }
        _ = next()
        let inner = try list(variant: variant, until: [.char("]")])
        _ = next()
        return inner
    }

    /// A braced argument as plain text (environment names, `\text`, `\operatorname`).
    private mutating func rawArgument() throws -> String {
        skipSpaces()
        guard case .begin = peek else {
            if case .char(let c) = next() { return String(c) }
            throw Unsupported(reason: "missing text argument")
        }
        _ = next()
        var out = "", level = 0
        while true {
            switch next() {
            case .eof: throw Unsupported(reason: "unclosed text")
            case .begin: level += 1; out += "{"
            case .end:
                if level == 0 { return out }
                level -= 1; out += "}"
            case .char(let c): out.append(c)
            case .command(let n):
                // Text escapes; any other command inside text is beyond stage 1.
                switch n {
                case "$", "%", "&", "#", "_", "{", "}": out += n
                case " ", "space", "nobreakspace": out += " "
                case ",", "thinspace": out += "\u{2009}"
                case "textbackslash": out += "\\"
                case "\\": throw Unsupported(reason: "line break in text")
                default: throw Unsupported(reason: "\\\(n) in text")
                }
            case .sup: out += "^"
            case .sub: out += "_"
            case .align: out += "&"
            }
        }
    }

    // MARK: Atoms

    private mutating func atom(variant: Variant) throws -> [MathNode] {
        // Unbraced arguments (`\sqrt\sqrt\sqrt x`) recurse through here without passing `list`.
        depth += 1
        defer { depth -= 1 }
        guard depth < 100 else { throw Unsupported(reason: "nesting") }
        switch next() {
        case .begin:
            let inner = try list(variant: variant, until: [.end])
            _ = next()
            return [.group(inner, .ord)]
        case .char(let c):
            return [try Self.character(c, variant: variant)]
        case .command(let name):
            return try command(name, variant: variant)
        default:
            throw Unsupported(reason: "unexpected token")
        }
    }

    static func character(_ c: Character, variant: Variant) throws -> MathNode {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { throw Unsupported(reason: "combined character") }
        if let mapped = letter(s, variant) { return .symbol(mapped, .ord) }
        switch c {
        case "+": return .symbol("+", .bin)
        case "-": return .symbol("\u{2212}", .bin)
        case "*": return .symbol("\u{2217}", .bin)
        case "=", "<", ">": return .symbol(s, .rel)
        case ":": return .symbol(":", .rel)
        case "(", "[": return .symbol(s, .open)
        case ")", "]", "!", "?": return .symbol(s, .close)
        case ",", ";": return .symbol(s, .punct)
        case "~": return .space(0.25, mu: false)
        case "\"", "#", "$", "&", "\\": throw Unsupported(reason: "character \(c)")
        default: break
        }
        if let known = Symbols.byScalar[s] { return .symbol(s, known) }
        return .symbol(s, .ord)
    }

    /// The codepoint a letter or digit takes in `variant`; nil for everything else.
    static func letter(_ s: Unicode.Scalar, _ variant: Variant) -> Unicode.Scalar? {
        let v = s.value
        let upper = (0x41...0x5A).contains(v), lower = (0x61...0x7A).contains(v), digit = (0x30...0x39).contains(v)
        let greekLower = (0x3B1...0x3C9).contains(v), greekUpper = (0x391...0x3A9).contains(v)
        let greekVar: [UInt32: UInt32] = [0x3F5: 0x1D716, 0x3D1: 0x1D717, 0x3F0: 0x1D718, 0x3D5: 0x1D719, 0x3F1: 0x1D71A, 0x3D6: 0x1D71B]
        func u(_ x: UInt32) -> Unicode.Scalar? { Unicode.Scalar(x) }
        guard upper || lower || digit || greekLower || greekUpper || greekVar[v] != nil else { return nil }
        switch variant {
        case .normal, .italic:
            if digit { return s }
            if upper { return u(0x1D434 + v - 0x41) }
            if lower { return v == 0x68 ? "\u{210E}" : u(0x1D44E + v - 0x61) }
            if greekLower { return u(0x1D6FC + v - 0x3B1) }
            if let g = greekVar[v] { return u(g) }
            // Capital Greek stays upright, as in TeX and KaTeX; \mathit makes it italic.
            return variant == .italic ? u(0x1D6E2 + v - 0x391) : s
        case .roman: return s
        case .bold:
            if digit { return u(0x1D7CE + v - 0x30) }
            if upper { return u(0x1D400 + v - 0x41) }
            if lower { return u(0x1D41A + v - 0x61) }
            if greekUpper { return u(0x1D6A8 + v - 0x391) }
            if greekLower { return u(0x1D6C2 + v - 0x3B1) }
            return s
        case .boldItalic:
            if digit { return u(0x1D7CE + v - 0x30) }
            if upper { return u(0x1D468 + v - 0x41) }
            if lower { return u(0x1D482 + v - 0x61) }
            if greekUpper { return u(0x1D71C + v - 0x391) }
            if greekLower { return u(0x1D736 + v - 0x3B1) }
            return s
        case .blackboard:
            let exceptions: [UInt32: UInt32] = [0x43: 0x2102, 0x48: 0x210D, 0x4E: 0x2115, 0x50: 0x2119, 0x51: 0x211A, 0x52: 0x211D, 0x5A: 0x2124]
            if let e = exceptions[v] { return u(e) }
            if digit { return u(0x1D7D8 + v - 0x30) }
            if upper { return u(0x1D538 + v - 0x41) }
            if lower { return u(0x1D552 + v - 0x61) }
            return s
        case .calligraphic:
            let exceptions: [UInt32: UInt32] = [0x42: 0x212C, 0x45: 0x2130, 0x46: 0x2131, 0x48: 0x210B, 0x49: 0x2110, 0x4C: 0x2112, 0x4D: 0x2133,
                                                0x52: 0x211B, 0x65: 0x212F, 0x67: 0x210A, 0x6F: 0x2134]
            if let e = exceptions[v] { return u(e) }
            if upper { return u(0x1D49C + v - 0x41) }
            if lower { return u(0x1D4B6 + v - 0x61) }
            return s
        case .fraktur:
            let exceptions: [UInt32: UInt32] = [0x43: 0x212D, 0x48: 0x210C, 0x49: 0x2111, 0x52: 0x211C, 0x5A: 0x2128]
            if let e = exceptions[v] { return u(e) }
            if upper { return u(0x1D504 + v - 0x41) }
            if lower { return u(0x1D51E + v - 0x61) }
            return s
        case .sans:
            if digit { return u(0x1D7E2 + v - 0x30) }
            if upper { return u(0x1D5A0 + v - 0x41) }
            if lower { return u(0x1D5BA + v - 0x61) }
            return s
        case .mono:
            if digit { return u(0x1D7F6 + v - 0x30) }
            if upper { return u(0x1D670 + v - 0x41) }
            if lower { return u(0x1D68A + v - 0x61) }
            return s
        }
    }

    private mutating func command(_ name: String, variant: Variant) throws -> [MathNode] {
        if let (scalar, cls) = Symbols.table[name] {
            if let greek = Symbols.greek[name] { return [.symbol(Self.letter(greek, variant) ?? greek, .ord)] }
            return [.symbol(scalar, cls)]
        }
        if let greek = Symbols.greek[name] { return [.symbol(Self.letter(greek, variant) ?? greek, .ord)] }
        if let op = Symbols.largeOps[name] { return [try limits(.largeOp(op, limits: nil))] }
        if let limits = Symbols.namedOps[name] {
            let text = name == "limsup" ? "lim\u{2009}sup" : name == "liminf" ? "lim\u{2009}inf" : name
            return [try self.limits(.namedOp(text, limits: limits))]
        }
        if let em = Symbols.spaces[name] { return [.space(em, mu: false)] }
        if let accent = Symbols.accents[name] { return [.accent(accent.0, try argument(variant: variant), stretchy: accent.1)] }
        if let v = Symbols.fonts[name] {
            let body = try argument(variant: v)
            // KaTeX's font.ts: `\boldsymbol{+}` stays a binary operator, `\boldsymbol{=}` a relation.
            return [.group(body, name == "boldsymbol" || name == "bm" ? Self.mainClass(body) : .ord)]
        }
        if let cls = Symbols.classCommands[name] {
            let body = try argument(variant: variant)
            return [try limits(.group(body, cls))]
        }
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac", "binom", "dbinom", "tbinom":
            let num = try argument(variant: variant), den = try argument(variant: variant)
            let style: MathStyleKind? = name.hasPrefix("d") || name == "cfrac" ? .display : name.hasPrefix("t") ? .text : nil
            let binom = name.hasSuffix("binom")
            return [.frac(num: num, den: den, rule: !binom, style: style, left: binom ? "(" : nil, right: binom ? ")" : nil)]
        case "sqrt":
            let index = try optionalArgument(variant: variant)
            return [.sqrt(try argument(variant: variant), index: index)]
        case "left":
            let left = try delimiter()
            var body: [MathNode] = []
            while true {
                body += try list(variant: variant, until: [.command("right"), .command("middle")])
                if case .command("middle") = next() { body.append(.middle(try delimiter())); continue }
                break
            }
            let right = try delimiter()
            return [.leftRight(left: left, body: body, right: right)]
        case "right", "middle": throw Unsupported(reason: "\\\(name) without \\left")
        case "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl", "bigr", "Bigr", "biggr", "Biggr", "bigm", "Bigm", "biggm", "Biggm":
            let size = name.lowercased().hasPrefix("bigg") ? (name.first == "B" ? 4 : 3) : (name.first == "B" ? 2 : 1)
            let cls: MathClass = name.hasSuffix("l") ? .open : name.hasSuffix("r") ? .close : name.hasSuffix("m") ? .rel : .ord
            guard let d = try delimiter() else { return [.space(0.12, mu: false)] }
            return [.sizedDelim(d, size: size, cls)]
        case "text", "textrm", "textnormal", "textup", "textmd", "mbox", "hbox", "textsf", "texttt":
            return [.text(try rawArgument(), name == "textsf" ? .sans : name == "texttt" ? .mono : .roman)]
        case "textbf": return [.text(try rawArgument(), .bold)]
        case "textit", "emph": return [.text(try rawArgument(), .italic)]
        case "operatorname", "operatorname*":
            let text = try rawArgument().filter { !$0.isWhitespace }
            return [try limits(.namedOp(text, limits: name.hasSuffix("*")))]
        case "overline": return [.overline(try argument(variant: variant))]
        case "underline": return [.underline(try argument(variant: variant))]
        case "overbrace": return [try limits(.overUnder(base: try argument(variant: variant), over: nil, under: nil, brace: "\u{23DE}", .op))]
        case "underbrace": return [try limits(.overUnder(base: try argument(variant: variant), over: nil, under: nil, brace: "\u{23DF}", .op))]
        case "overset", "stackrel":
            let over = try argument(variant: variant), base = try argument(variant: variant)
            return [.overUnder(base: base, over: over, under: nil, brace: nil, name == "stackrel" ? .rel : Self.mainClass(base))]
        case "underset":
            let under = try argument(variant: variant), base = try argument(variant: variant)
            return [.overUnder(base: base, over: nil, under: under, brace: nil, Self.mainClass(base))]
        case "textcolor":
            let color = try MathColor(try rawArgument())
            return [.colored(color, try argument(variant: variant))]
        case "cancel", "bcancel", "xcancel":
            return [.cancel(try argument(variant: variant), up: name != "bcancel", down: name != "cancel")]
        case "xrightarrow", "xleftarrow", "xleftrightarrow", "xRightarrow", "xLeftarrow", "xLeftrightarrow", "xmapsto":
            let below = try optionalArgument(variant: variant)
            let arrows: [String: Unicode.Scalar] = ["xrightarrow": "\u{2192}", "xleftarrow": "\u{2190}", "xleftrightarrow": "\u{2194}",
                                                    "xRightarrow": "\u{21D2}", "xLeftarrow": "\u{21D0}", "xLeftrightarrow": "\u{21D4}", "xmapsto": "\u{21A6}"]
            return [.xArrow(arrows[name]!, above: try argument(variant: variant), below: below)]
        case "tag":
            skipSpaces()
            var starred = false
            if case .char("*") = peek { _ = next(); starred = true }
            tags += 1
            // Top level: `list` and this `atom` are the only frames.
            guard depth == 2 else { throw Unsupported(reason: "\\tag inside a group") }
            let text = try rawArgument()
            return [.tag(starred ? text : "(\(text))")]
        case "displaystyle": return [.style(.display)]
        case "textstyle": return [.style(.text)]
        case "scriptstyle": return [.style(.script)]
        case "scriptscriptstyle": return [.style(.scriptScript)]
        case "phantom": return [.phantom(try argument(variant: variant), width: true, height: true)]
        case "hphantom": return [.phantom(try argument(variant: variant), width: true, height: false)]
        case "vphantom": return [.phantom(try argument(variant: variant), width: false, height: true)]
        case "boxed": return [.boxed(try argument(variant: variant))]
        case "not":
            skipSpaces()
            guard case .command(let n) = peek, let negated = Symbols.negations[n] else {
                if case .char(let c) = peek, let negated = Symbols.negations[String(c)] { _ = next(); return [.symbol(negated, .rel)] }
                throw Unsupported(reason: "\\not before this symbol")
            }
            _ = next()
            return [.symbol(negated, .rel)]
        case "implies", "impliedby", "iff":
            let arrow: Unicode.Scalar = name == "implies" ? "\u{27F9}" : name == "impliedby" ? "\u{27F8}" : "\u{27FA}"
            return [.space(5, mu: true), .symbol(arrow, .rel), .space(5, mu: true)]
        case "bmod": return [.namedOpBin("mod")]
        case "pmod":
            let arg = try argument(variant: variant)
            return [.space(18, mu: true), .symbol("(", .open), .namedOp("mod", limits: false), .space(6, mu: true)] + arg + [.symbol(")", .close)]
        case "mod":
            let arg = try argument(variant: variant)
            return [.space(18, mu: true), .namedOp("mod", limits: false), .space(6, mu: true)] + arg
        case "hspace", "kern", "mkern", "mskip", "hskip":
            let raw = name == "hspace" ? try rawArgument() : try rawDimension()
            return [try Self.dimension(raw)]
        case "substack":
            skipSpaces()
            guard case .begin = next() else { throw Unsupported(reason: "\\substack argument") }
            let (rows, gaps, _) = try arrayRows(variant: variant, end: .end)
            return [.array(rows: rows, columns: ["c"], kind: .substack, gaps: gaps)]
        case "begin": return [try environment(variant: variant)]
        case "limits", "nolimits": throw Unsupported(reason: "\\\(name) after a non-operator")
        default:
            throw Unsupported(reason: "\\\(name)")
        }
    }

    /// `\limits` or `\nolimits` right after an operator.
    private mutating func limits(_ node: MathNode) throws -> MathNode {
        skipSpaces()
        guard case .command(let n) = peek, n == "limits" || n == "nolimits" else { return node }
        _ = next()
        let on = n == "limits"
        switch node {
        case .largeOp(let s, _): return .largeOp(s, limits: on)
        // Forced limits stack in any style; `.overUnder` with nothing over or under does that.
        case .namedOp(let t, _): return on ? .overUnder(base: [.namedOp(t, limits: true)], over: nil, under: nil, brace: nil, .op) : .namedOp(t, limits: false)
        case .group(let b, .op) where on: return .overUnder(base: b, over: nil, under: nil, brace: nil, .op)
        default: return node
        }
    }

    private static func mainClass(_ base: [MathNode]) -> MathClass {
        if base.count == 1, case .symbol(_, let c) = base[0] { return c }
        return .ord
    }

    /// A delimiter after `\left`, `\right`, `\big`: nil for `.`.
    private mutating func delimiter() throws -> Unicode.Scalar? {
        skipSpaces()
        switch next() {
        case .char("."): return nil
        case .char(let c):
            guard "()[]|/<>".contains(c), let s = c.unicodeScalars.first else { throw Unsupported(reason: "delimiter \(c)") }
            return c == "<" ? "\u{27E8}" : c == ">" ? "\u{27E9}" : s
        case .command(let n):
            if let d = Symbols.delimiters[n] { return d }
            throw Unsupported(reason: "delimiter \\\(n)")
        default: throw Unsupported(reason: "missing delimiter")
        }
    }

    private mutating func rawDimension() throws -> String {
        skipSpaces()
        if case .begin = peek { return try rawArgument() }
        var out = ""
        while case .char(let c) = peek, c.isNumber || c == "." || c == "-" || c.isLetter, out.count < 12 {
            out.append(c); _ = next()
            if out.hasSuffix("em") || out.hasSuffix("mu") || out.hasSuffix("pt") || out.hasSuffix("ex") { break }
        }
        return out
    }

    static func dimension(_ raw: String) throws -> MathNode {
        let s = raw.trimmingCharacters(in: .whitespaces)
        for (unit, scale, mu) in [("em", 1.0, false), ("ex", 0.431, false), ("pt", 0.1, false), ("mu", 1.0, true)] where s.hasSuffix(unit) {
            guard let v = Double(s.dropLast(2).trimmingCharacters(in: .whitespaces)), abs(v) < 100 else { break }
            return .space(CGFloat(v * scale), mu: mu)
        }
        throw Unsupported(reason: "dimension \(raw)")
    }

    // MARK: Environments

    private mutating func environment(variant: Variant) throws -> MathNode {
        let name = try rawArgument()
        var columns: [Character] = []
        if name == "array" {
            columns = Array(try rawArgument().filter { !$0.isWhitespace })
            guard columns.contains(where: { "lcr".contains($0) }), columns.allSatisfy({ "lcr|".contains($0) }) else { throw Unsupported(reason: "array columns") }
        }
        // `alignedat{n}` names its column pairs first.
        if name == "alignedat" { guard let n = Int(try rawArgument()), (1...20).contains(n) else { throw Unsupported(reason: "alignedat count") } }
        let (rows, gaps, hlines) = try arrayRows(variant: variant, end: .command("end"))
        _ = next()
        guard hlines.isEmpty || name == "array" else { throw Unsupported(reason: "\\hline outside array") }
        guard try rawArgument() == name else { throw Unsupported(reason: "mismatched \\end") }
        let delims: [String: (Unicode.Scalar?, Unicode.Scalar?)] = [
            "pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"), "vmatrix": ("|", "|"), "Vmatrix": ("\u{2016}", "\u{2016}"),
        ]
        switch name {
        case "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix":
            let array = MathNode.array(rows: rows, columns: [], kind: .matrix, gaps: gaps)
            guard let (l, r) = delims[name] else { return array }
            return .leftRight(left: l, body: [array], right: r)
        case "smallmatrix":
            return .array(rows: rows, columns: [], kind: .smallMatrix, gaps: gaps)
        case "cases", "dcases":
            let array = MathNode.array(rows: rows, columns: ["l", "l"], kind: .cases, gaps: gaps)
            return .leftRight(left: "{", body: name == "dcases" ? [.style(.display), array] : [array], right: nil)
        case "rcases":
            return .leftRight(left: nil, body: [.array(rows: rows, columns: ["l", "l"], kind: .cases, gaps: gaps)], right: "}")
        case "aligned", "align", "align*", "split", "eqnarray", "eqnarray*":
            return .array(rows: rows, columns: [], kind: .aligned, gaps: gaps)
        case "alignedat":
            return .array(rows: rows, columns: [], kind: .alignedAt, gaps: gaps)
        case "gathered", "gather", "gather*":
            return .array(rows: rows, columns: ["c"], kind: .gathered, gaps: gaps)
        case "equation", "equation*":
            // ponytail: no "(1)" number on `equation`; add KaTeX's auto tag if replies use it
            guard rows.count == 1, rows[0].count == 1 else { throw Unsupported(reason: "equation with rows") }
            return .group(rows[0][0], .ord)
        case "array":
            return .array(rows: rows, columns: columns, kind: .array, gaps: gaps, hlines: hlines)
        default:
            throw Unsupported(reason: "environment \(name)")
        }
    }

    /// Cells split by `&` and rows by `\\`, until `end`. A trailing `\\` adds no row.
    private mutating func arrayRows(variant: Variant, end: Token) throws -> (rows: [[[MathNode]]], gaps: [CGFloat], hlines: [Int]) {
        var rows: [[[MathNode]]] = [], row: [[MathNode]] = [], gaps: [CGFloat] = [], hlines: [Int] = []
        while true {
            // `\hline` at the start of a row draws a rule above it.
            if row.isEmpty {
                skipSpaces()
                while case .command("hline") = peek { _ = next(); hlines.append(rows.count); skipSpaces() }
            }
            let cell = try list(variant: variant, until: [.align, .command("\\"), .command("cr"), end])
            row.append(cell)
            switch next() {
            case .align: continue
            case .command("\\"), .command("cr"):
                // `\\[2pt]`: extra space after the row.
                skipSpaces()
                var gap: CGFloat = 0
                if case .char("[") = peek {
                    _ = next()
                    var raw = ""
                    while true {
                        let t = next()
                        if t == .char("]") { break }
                        guard case .char(let c) = t, raw.count < 16 else { throw Unsupported(reason: "row spacing") }
                        raw.append(c)
                    }
                    guard case .space(let em, false) = try Self.dimension(raw) else { throw Unsupported(reason: "row spacing in mu") }
                    gap = em
                }
                rows.append(row); row = []
                gaps.append(gap)
            default:
                if !(row.count == 1 && row[0].isEmpty) || rows.isEmpty { rows.append(row) }
                gaps = Array((gaps + [0]).prefix(rows.count))
                hlines = hlines.map { min($0, rows.count) }
                if end == .end { return (rows, gaps, hlines) }
                at -= 1
                return (rows, gaps, hlines)
            }
        }
    }
}

extension MathNode {
    /// `\bmod`: "mod" set as a binary operator.
    static func namedOpBin(_ text: String) -> MathNode { .group([.text(text, .roman)], .bin) }
}

/// Names TeX and KaTeX know, and the classes they set.
enum Symbols {
    static let greek: [String: Unicode.Scalar] = [
        "alpha": "\u{3B1}", "beta": "\u{3B2}", "gamma": "\u{3B3}", "delta": "\u{3B4}", "epsilon": "\u{3F5}", "varepsilon": "\u{3B5}",
        "zeta": "\u{3B6}", "eta": "\u{3B7}", "theta": "\u{3B8}", "vartheta": "\u{3D1}", "iota": "\u{3B9}", "kappa": "\u{3BA}",
        "varkappa": "\u{3F0}", "lambda": "\u{3BB}", "mu": "\u{3BC}", "nu": "\u{3BD}", "xi": "\u{3BE}", "omicron": "\u{3BF}", "pi": "\u{3C0}",
        "varpi": "\u{3D6}", "rho": "\u{3C1}", "varrho": "\u{3F1}", "sigma": "\u{3C3}", "varsigma": "\u{3C2}", "tau": "\u{3C4}",
        "upsilon": "\u{3C5}", "phi": "\u{3D5}", "varphi": "\u{3C6}", "chi": "\u{3C7}", "psi": "\u{3C8}", "omega": "\u{3C9}",
        "Gamma": "\u{393}", "Delta": "\u{394}", "Theta": "\u{398}", "Lambda": "\u{39B}", "Xi": "\u{39E}", "Pi": "\u{3A0}", "Sigma": "\u{3A3}",
        "Upsilon": "\u{3A5}", "Phi": "\u{3A6}", "Psi": "\u{3A8}", "Omega": "\u{3A9}",
    ]

    static let table: [String: (Unicode.Scalar, MathClass)] = {
        var t: [String: (Unicode.Scalar, MathClass)] = [:]
        func add(_ cls: MathClass, _ pairs: [(String, Unicode.Scalar)]) { for (n, s) in pairs { t[n] = (s, cls) } }
        add(.ord, [("infty", "\u{221E}"), ("partial", "\u{1D715}"), ("nabla", "\u{2207}"), ("forall", "\u{2200}"), ("exists", "\u{2203}"),
                   ("nexists", "\u{2204}"), ("emptyset", "\u{2205}"), ("varnothing", "\u{2205}"), ("neg", "\u{AC}"), ("lnot", "\u{AC}"),
                   ("top", "\u{22A4}"), ("bot", "\u{22A5}"), ("angle", "\u{2220}"), ("triangle", "\u{25B3}"), ("Box", "\u{25A1}"),
                   ("square", "\u{25A1}"), ("ell", "\u{2113}"), ("hbar", "\u{210F}"), ("hslash", "\u{210F}"), ("Re", "\u{211C}"),
                   ("Im", "\u{2111}"), ("aleph", "\u{2135}"), ("beth", "\u{2136}"), ("wp", "\u{2118}"), ("prime", "\u{2032}"),
                   ("backslash", "\\"), ("surd", "\u{221A}"), ("flat", "\u{266D}"), ("natural", "\u{266E}"), ("sharp", "\u{266F}"),
                   ("clubsuit", "\u{2663}"), ("diamondsuit", "\u{2662}"), ("heartsuit", "\u{2661}"), ("spadesuit", "\u{2660}"),
                   ("S", "\u{A7}"), ("P", "\u{B6}"), ("checkmark", "\u{2713}"), ("degree", "\u{B0}"), ("vdots", "\u{22EE}"),
                   ("#", "#"), ("$", "$"), ("%", "%"), ("&", "&"), ("_", "_"), ("vert", "|"), ("|", "\u{2225}"), ("Vert", "\u{2225}"),
                   ("imath", "\u{1D6A4}"), ("jmath", "\u{1D6A5}"), ("circledR", "\u{AE}"), ("copyright", "\u{A9}"), ("dag", "\u{2020}"),
                   ("ddag", "\u{2021}"), ("mho", "\u{2127}"), ("eth", "\u{F0}"), ("complement", "\u{2201}"), ("blacksquare", "\u{25A0}"),
                   ("lozenge", "\u{25CA}"), ("star", "\u{22C6}")])
        add(.inner, [("cdots", "\u{22EF}"), ("ldots", "\u{2026}"), ("dots", "\u{2026}"), ("dotsc", "\u{2026}"), ("dotsb", "\u{22EF}"),
                     ("dotsm", "\u{22EF}"), ("dotsi", "\u{22EF}"), ("ddots", "\u{22F1}")])
        add(.open, [("{", "{"), ("lbrace", "{"), ("lbrack", "["), ("langle", "\u{27E8}"), ("lfloor", "\u{230A}"), ("lceil", "\u{2308}"),
                    ("lvert", "|"), ("lVert", "\u{2016}"), ("lgroup", "\u{27EE}")])
        add(.close, [("}", "}"), ("rbrace", "}"), ("rbrack", "]"), ("rangle", "\u{27E9}"), ("rfloor", "\u{230B}"), ("rceil", "\u{2309}"),
                     ("rvert", "|"), ("rVert", "\u{2016}"), ("rgroup", "\u{27EF}")])
        add(.punct, [("colon", ":"), ("cdotp", "\u{22C5}"), ("ldotp", ".")])
        add(.bin, [("pm", "\u{B1}"), ("mp", "\u{2213}"), ("times", "\u{D7}"), ("div", "\u{F7}"), ("cdot", "\u{22C5}"), ("ast", "\u{2217}"),
                   ("circ", "\u{2218}"), ("bullet", "\u{2219}"), ("oplus", "\u{2295}"), ("ominus", "\u{2296}"),
                   ("otimes", "\u{2297}"), ("oslash", "\u{2298}"), ("odot", "\u{2299}"), ("cup", "\u{222A}"), ("cap", "\u{2229}"),
                   ("sqcup", "\u{2294}"), ("sqcap", "\u{2293}"), ("uplus", "\u{228E}"), ("setminus", "\u{2216}"), ("smallsetminus", "\u{2216}"),
                   ("wedge", "\u{2227}"), ("land", "\u{2227}"), ("vee", "\u{2228}"), ("lor", "\u{2228}"), ("diamond", "\u{22C4}"),
                   ("bigtriangleup", "\u{25B3}"), ("bigtriangledown", "\u{25BD}"), ("triangleleft", "\u{25C3}"), ("triangleright", "\u{25B9}"),
                   ("wr", "\u{2240}"), ("amalg", "\u{2A3F}"), ("dagger", "\u{2020}"), ("ddagger", "\u{2021}"), ("centerdot", "\u{22C5}")])
        add(.rel, [("le", "\u{2264}"), ("leq", "\u{2264}"), ("ge", "\u{2265}"), ("geq", "\u{2265}"), ("leqslant", "\u{2A7D}"),
                   ("geqslant", "\u{2A7E}"), ("ne", "\u{2260}"), ("neq", "\u{2260}"), ("equiv", "\u{2261}"), ("approx", "\u{2248}"),
                   ("sim", "\u{223C}"), ("simeq", "\u{2243}"), ("cong", "\u{2245}"), ("propto", "\u{221D}"), ("in", "\u{2208}"),
                   ("notin", "\u{2209}"), ("ni", "\u{220B}"), ("owns", "\u{220B}"), ("subset", "\u{2282}"), ("supset", "\u{2283}"),
                   ("subseteq", "\u{2286}"), ("supseteq", "\u{2287}"), ("subsetneq", "\u{228A}"), ("supsetneq", "\u{228B}"),
                   ("sqsubseteq", "\u{2291}"), ("sqsupseteq", "\u{2292}"), ("ll", "\u{226A}"), ("gg", "\u{226B}"), ("prec", "\u{227A}"),
                   ("succ", "\u{227B}"), ("preceq", "\u{2AAF}"), ("succeq", "\u{2AB0}"), ("perp", "\u{22A5}"), ("models", "\u{22A8}"),
                   ("vdash", "\u{22A2}"), ("dashv", "\u{22A3}"), ("asymp", "\u{224D}"), ("doteq", "\u{2250}"), ("bowtie", "\u{22C8}"),
                   ("smile", "\u{2323}"), ("frown", "\u{2322}"), ("coloneqq", "\u{2254}"), ("triangleq", "\u{225C}"), ("lesssim", "\u{2272}"),
                   ("gtrsim", "\u{2273}"), ("nless", "\u{226E}"), ("ngtr", "\u{226F}"), ("nleq", "\u{2270}"), ("ngeq", "\u{2271}"),
                   ("nsim", "\u{2241}"), ("ncong", "\u{2247}"), ("nsubseteq", "\u{2288}"), ("nsupseteq", "\u{2289}"), ("mid", "\u{2223}"),
                   ("nmid", "\u{2224}"), ("parallel", "\u{2225}"), ("nparallel", "\u{2226}"), ("lt", "<"), ("gt", ">"),
                   ("to", "\u{2192}"), ("rightarrow", "\u{2192}"), ("leftarrow", "\u{2190}"), ("gets", "\u{2190}"),
                   ("leftrightarrow", "\u{2194}"), ("Rightarrow", "\u{21D2}"), ("Leftarrow", "\u{21D0}"), ("Leftrightarrow", "\u{21D4}"),
                   ("longrightarrow", "\u{27F6}"), ("longleftarrow", "\u{27F5}"), ("longleftrightarrow", "\u{27F7}"),
                   ("Longrightarrow", "\u{27F9}"), ("Longleftarrow", "\u{27F8}"), ("Longleftrightarrow", "\u{27FA}"), ("mapsto", "\u{21A6}"),
                   ("longmapsto", "\u{27FC}"), ("hookrightarrow", "\u{21AA}"), ("hookleftarrow", "\u{21A9}"), ("uparrow", "\u{2191}"),
                   ("downarrow", "\u{2193}"), ("updownarrow", "\u{2195}"), ("Uparrow", "\u{21D1}"), ("Downarrow", "\u{21D3}"),
                   ("nearrow", "\u{2197}"), ("searrow", "\u{2198}"), ("swarrow", "\u{2199}"), ("nwarrow", "\u{2196}"),
                   ("rightharpoonup", "\u{21C0}"), ("leftharpoonup", "\u{21BC}"), ("rightleftharpoons", "\u{21CC}"), ("leadsto", "\u{21DD}"),
                   ("twoheadrightarrow", "\u{21A0}"), ("therefore", "\u{2234}"), ("because", "\u{2235}"), ("approxeq", "\u{224A}"),
                   ("vDash", "\u{22A8}"), ("sqsubset", "\u{228F}"), ("sqsupset", "\u{2290}"), ("Subset", "\u{22D0}"), ("Supset", "\u{22D1}")])
        return t
    }()

    static let byScalar: [Unicode.Scalar: MathClass] = {
        var out: [Unicode.Scalar: MathClass] = [:]
        for (_, (s, c)) in table where out[s] == nil { out[s] = c }
        for (_, s) in largeOps { out[s] = .op }
        out["|"] = .ord; out["/"] = .ord; out["."] = .ord
        return out
    }()

    static let largeOps: [String: Unicode.Scalar] = [
        "sum": "\u{2211}", "prod": "\u{220F}", "coprod": "\u{2210}", "bigcup": "\u{22C3}", "bigcap": "\u{22C2}", "bigvee": "\u{22C1}",
        "bigwedge": "\u{22C0}", "bigoplus": "\u{2A01}", "bigotimes": "\u{2A02}", "bigodot": "\u{2A00}", "biguplus": "\u{2A04}",
        "bigsqcup": "\u{2A06}", "int": "\u{222B}", "iint": "\u{222C}", "iiint": "\u{222D}", "oint": "\u{222E}", "oiint": "\u{222F}",
        "intop": "\u{222B}", "smallint": "\u{222B}",
    ]
    static let integrals: Set<Unicode.Scalar> = ["\u{222B}", "\u{222C}", "\u{222D}", "\u{222E}", "\u{222F}"]

    /// Named operators and whether they take limits in display style.
    static let namedOps: [String: Bool] = [
        "lim": true, "limsup": true, "liminf": true, "max": true, "min": true, "sup": true, "inf": true, "det": true, "gcd": true, "Pr": true,
        "sin": false, "cos": false, "tan": false, "cot": false, "sec": false, "csc": false, "sinh": false, "cosh": false, "tanh": false,
        "coth": false, "arcsin": false, "arccos": false, "arctan": false, "log": false, "ln": false, "lg": false, "exp": false, "deg": false,
        "dim": false, "hom": false, "ker": false, "arg": false, "sgn": false, "tr": false, "Tr": false,
    ]

    /// Spaces in em (18mu is 1em).
    static let spaces: [String: CGFloat] = [
        ",": 3.0 / 18, "thinspace": 3.0 / 18, ":": 4.0 / 18, ">": 4.0 / 18, "medspace": 4.0 / 18, ";": 5.0 / 18, "thickspace": 5.0 / 18,
        "!": -3.0 / 18, "negthinspace": -3.0 / 18, "negmedspace": -4.0 / 18, "negthickspace": -5.0 / 18, "quad": 1, "qquad": 2,
        " ": 0.25, "enspace": 0.5, "nobreakspace": 0.25, "space": 0.25,
    ]

    /// Accent commands: the combining mark and whether it stretches over a wide base.
    static let accents: [String: (Unicode.Scalar, Bool)] = [
        "hat": ("\u{302}", false), "widehat": ("\u{302}", true), "check": ("\u{30C}", false), "widecheck": ("\u{30C}", true),
        "tilde": ("\u{303}", false), "widetilde": ("\u{303}", true), "acute": ("\u{301}", false), "grave": ("\u{300}", false),
        "dot": ("\u{307}", false), "ddot": ("\u{308}", false), "dddot": ("\u{20DB}", false), "breve": ("\u{306}", false),
        "bar": ("\u{304}", false), "vec": ("\u{20D7}", false), "mathring": ("\u{30A}", false),
        "overrightarrow": ("\u{2192}", true), "overleftarrow": ("\u{2190}", true), "overleftrightarrow": ("\u{2194}", true),
    ]

    static let fonts: [String: TeXParser.Variant] = [
        "mathrm": .roman, "mathup": .roman, "mathit": .italic, "mathbf": .bold, "boldsymbol": .boldItalic, "bm": .boldItalic,
        "mathbb": .blackboard, "mathcal": .calligraphic, "mathscr": .calligraphic, "mathfrak": .fraktur, "mathsf": .sans,
        "mathtt": .mono, "mathnormal": .normal,
    ]

    static let classCommands: [String: MathClass] = [
        "mathord": .ord, "mathop": .op, "mathbin": .bin, "mathrel": .rel, "mathopen": .open, "mathclose": .close,
        "mathpunct": .punct, "mathinner": .inner,
    ]

    static let delimiters: [String: Unicode.Scalar] = [
        "{": "{", "}": "}", "lbrace": "{", "rbrace": "}", "lbrack": "[", "rbrack": "]", "langle": "\u{27E8}", "rangle": "\u{27E9}",
        "lfloor": "\u{230A}", "rfloor": "\u{230B}", "lceil": "\u{2308}", "rceil": "\u{2309}", "vert": "|", "|": "\u{2016}",
        "Vert": "\u{2016}", "lvert": "|", "rvert": "|", "lVert": "\u{2016}", "rVert": "\u{2016}", "backslash": "\\",
        "uparrow": "\u{2191}", "downarrow": "\u{2193}", "updownarrow": "\u{2195}", "Uparrow": "\u{21D1}", "Downarrow": "\u{21D3}",
        "lgroup": "\u{27EE}", "rgroup": "\u{27EF}", "lt": "\u{27E8}", "gt": "\u{27E9}", "mid": "\u{2223}",
    ]

    /// `\not` before these.
    static let negations: [String: Unicode.Scalar] = [
        "=": "\u{2260}", "<": "\u{226E}", ">": "\u{226F}", "in": "\u{2209}", "le": "\u{2270}", "leq": "\u{2270}", "ge": "\u{2271}",
        "geq": "\u{2271}", "subset": "\u{2284}", "supset": "\u{2285}", "subseteq": "\u{2288}", "supseteq": "\u{2289}",
        "equiv": "\u{2262}", "sim": "\u{2241}", "approx": "\u{2249}", "cong": "\u{2247}", "mid": "\u{2224}", "parallel": "\u{2226}",
        "ni": "\u{220C}", "exists": "\u{2204}", "simeq": "\u{2244}", "prec": "\u{2280}", "succ": "\u{2281}",
    ]
}

/// A color `\\color` names: KaTeX's CSS names or `#rgb` and `#rrggbb`.
struct MathColor: Sendable, Hashable {
    let r: CGFloat, g: CGFloat, b: CGFloat

    init(_ raw: String) throws {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let named: [String: UInt32] = [
            "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "yellow": 0xFFFF00,
            "cyan": 0x00FFFF, "magenta": 0xFF00FF, "orange": 0xFFA500, "purple": 0x800080, "brown": 0xA52A2A, "gray": 0x808080,
            "grey": 0x808080, "pink": 0xFFC0CB, "teal": 0x008080, "olive": 0x808000, "navy": 0x000080, "maroon": 0x800000,
            "lime": 0x00FF00, "violet": 0xEE82EE, "darkgray": 0xA9A9A9, "lightgray": 0xD3D3D3, "darkblue": 0x00008B,
            "darkred": 0x8B0000, "darkgreen": 0x006400, "gold": 0xFFD700, "indigo": 0x4B0082, "crimson": 0xDC143C,
        ]
        var value: UInt32
        if let v = named[name] {
            value = v
        } else if name.hasPrefix("#"), let v = UInt32(name.dropFirst(), radix: 16), name.count == 7 || name.count == 4 {
            value = name.count == 7 ? v : ((v >> 8 & 0xF) * 0x110000) | ((v >> 4 & 0xF) * 0x1100) | ((v & 0xF) * 0x11)
        } else {
            throw TeXParser.Unsupported(reason: "color \(raw)")
        }
        r = CGFloat(value >> 16 & 0xFF) / 255; g = CGFloat(value >> 8 & 0xFF) / 255; b = CGFloat(value & 0xFF) / 255
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}
