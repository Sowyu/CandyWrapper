import Foundation

/// A CSS color in OKLab with alpha, the space every theme computation runs in. Components are not clamped,
/// as Chromium keeps them until it paints. `hueMissing` carries CSS's `none` hue for oklch interpolation.
public struct ThemeCSSColor: Sendable, Equatable {
    public var lab: SIMD3<Double>
    public var alpha: Double
    var hueMissing = false
    /// The components as written for an `oklch()` literal, so a huge chroma survives (themePalette.ts gamut maps it).
    var sourceLCH: SIMD3<Double>?

    public init(lab: SIMD3<Double>, alpha: Double = 1) { self.lab = lab; self.alpha = alpha }

    public static let transparent = ThemeCSSColor(lab: .zero, alpha: 0)

    // MARK: Conversions (CSS Color 4 sample code, the same matrices as OKLab.swift and themePalette.ts)

    static func linear(_ v: Double) -> Double {
        let x = abs(v), s: Double = v < 0 ? -1 : 1
        return s * (x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
    }

    static func gamma(_ v: Double) -> Double {
        let x = abs(v), s: Double = v < 0 ? -1 : 1
        return s * (x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
    }

    /// From gamma-encoded sRGB components (0...1, unclamped).
    public init(srgb r: Double, _ g: Double, _ b: Double, alpha: Double = 1) {
        let lr = Self.linear(r), lg = Self.linear(g), lb = Self.linear(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        lab = SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        self.alpha = alpha
    }

    public init(oklch l: Double, _ c: Double, _ h: Double?, alpha: Double = 1) {
        let rad = (h ?? 0) * .pi / 180
        lab = SIMD3(l, c * cos(rad), c * sin(rad))
        self.alpha = alpha
        hueMissing = h == nil
        sourceLCH = SIMD3(l, c, ((h ?? 0).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
    }

    /// Linear-light sRGB.
    var linearSRGB: SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Gamma-encoded sRGB, unclamped.
    public var srgb: SIMD3<Double> { let v = linearSRGB; return SIMD3(Self.gamma(v.x), Self.gamma(v.y), Self.gamma(v.z)) }

    /// Gamma-encoded Display P3, unclamped.
    var displayP3: SIMD3<Double> {
        let v = linearSRGB
        let p = SIMD3(0.8224621 * v.x + 0.1775380 * v.y,
                      0.0331941 * v.x + 0.9668058 * v.y,
                      0.0170827 * v.x + 0.0723974 * v.y + 0.9105199 * v.z)
        return SIMD3(Self.gamma(p.x), Self.gamma(p.y), Self.gamma(p.z))
    }

    var lch: SIMD3<Double> {
        if let sourceLCH { return sourceLCH }
        let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var h = atan2(lab.z, lab.y) * 180 / .pi
        if h < 0 { h += 360 }
        return SIMD3(lab.x, c, h)
    }

    /// The token form the design system draws with.
    public var token: TokenColor {
        let s = srgb, p = displayP3
        return TokenColor(srgb: SIMD4(s.x, s.y, s.z, alpha), displayP3: SIMD4(p.x, p.y, p.z, alpha))
    }

    // MARK: color-mix()

    public enum Space: String, Sendable { case srgb, oklab, oklch }

    /// `color-mix(in <space>, a p1, b p2)` with CSS Color 5's percentage normalization and premultiplied alpha.
    /// Percentages are 0...100; nil means omitted.
    public static func mix(_ space: Space, _ a: ThemeCSSColor, _ p1: Double?, _ b: ThemeCSSColor, _ p2: Double?) -> ThemeCSSColor {
        var w1 = p1.map { min(max($0, 0), 100) }, w2 = p2.map { min(max($0, 0), 100) }
        switch (w1, w2) {
        case (nil, nil): w1 = 50; w2 = 50
        case (let x?, nil): w2 = 100 - x
        case (nil, let y?): w1 = 100 - y
        default: break
        }
        let sum = w1! + w2!
        guard sum > 0 else { return .transparent }
        let alphaMultiplier = sum < 100 ? sum / 100 : 1
        let t1 = w1! / sum, t2 = w2! / sum
        let alpha = a.alpha * t1 + b.alpha * t2
        guard alpha > 0 else { return ThemeCSSColor(lab: .zero, alpha: 0) }
        func premix(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> SIMD3<Double> {
            (x * (a.alpha * t1) + y * (b.alpha * t2)) / alpha
        }
        var result: ThemeCSSColor
        switch space {
        case .oklab:
            result = ThemeCSSColor(lab: premix(a.lab, b.lab), alpha: alpha)
        case .srgb:
            let m = premix(a.srgb, b.srgb)
            result = ThemeCSSColor(srgb: m.x, m.y, m.z, alpha: alpha)
        case .oklch:
            let x = a.lch, y = b.lch
            // A missing (or powerless, achromatic) hue takes the other color's.
            let aMissing = a.hueMissing || x.y < 1e-6, bMissing = b.hueMissing || y.y < 1e-6
            var h1 = x.z, h2 = y.z
            if aMissing { h1 = h2 } else if bMissing { h2 = h1 }
            // Shorter hue interpolation.
            if h2 - h1 > 180 { h1 += 360 } else if h2 - h1 < -180 { h2 += 360 }
            let l = (x.x * a.alpha * t1 + y.x * b.alpha * t2) / alpha
            let c = (x.y * a.alpha * t1 + y.y * b.alpha * t2) / alpha
            let h = (h1 * t1 + h2 * t2).truncatingRemainder(dividingBy: 360)
            result = ThemeCSSColor(oklch: l, c, aMissing && bMissing ? nil : h, alpha: alpha)
        }
        result.alpha *= alphaMultiplier
        return result
    }

    // MARK: Parsing literal colors

    /// Parses a literal CSS color: hex, `rgb()`/`rgba()`, `hsl()`/`hsla()`, `oklch()`, `oklab()`, and the
    /// keywords `transparent`, `black` and `white`. Nil for anything else.
    // ponytail: no other named colors; theme files T3 writes hold oklch, add the CSS name table if imports need it
    public static func parse(_ text: String) -> ThemeCSSColor? {
        var p = ThemeCSSParser(text)
        guard let expr = try? p.expression(), p.atEnd, case .literal(let color) = expr else { return nil }
        return color
    }
}

/// A parsed theme token expression: literal colors, `var()` references and `color-mix()`.
indirect enum ThemeCSSExpression: Sendable {
    enum Percent: Sendable { case value(Double), variable(String) }
    case literal(ThemeCSSColor)
    case variable(String)
    case mix(ThemeCSSColor.Space, ThemeCSSExpression, Percent?, ThemeCSSExpression, Percent?)

    /// Resolves with colors and percentages for the variables. An unknown variable is transparent, as an
    /// invalid custom property would leave the color unset.
    func evaluate(colors: [String: ThemeCSSColor], percents: [String: Double]) -> ThemeCSSColor {
        switch self {
        case .literal(let c): return c
        case .variable(let name): return colors[name] ?? .transparent
        case .mix(let space, let a, let p1, let b, let p2):
            func pct(_ p: Percent?) -> Double? {
                switch p {
                case nil: nil
                case .value(let v): v
                case .variable(let name): percents[name] ?? 0
                }
            }
            return ThemeCSSColor.mix(space, a.evaluate(colors: colors, percents: percents), pct(p1),
                                     b.evaluate(colors: colors, percents: percents), pct(p2))
        }
    }

    static func parse(_ text: String) -> ThemeCSSExpression? {
        var p = ThemeCSSParser(text)
        guard let e = try? p.expression(), p.atEnd else { return nil }
        return e
    }
}

/// A small recursive-descent reader for the CSS that Chromium serializes for theme tokens.
struct ThemeCSSParser {
    struct Failure: Error {}
    private let chars: [Character]
    private var i = 0

    init(_ text: String) { chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var atEnd: Bool { mutating get { skipSpace(); return i >= chars.count } }

    private mutating func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

    private mutating func eat(_ c: Character) -> Bool {
        skipSpace()
        if i < chars.count, chars[i] == c { i += 1; return true }
        return false
    }

    private mutating func expect(_ c: Character) throws { if !eat(c) { throw Failure() } }

    private mutating func ident() -> String {
        skipSpace()
        let start = i
        while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "-" || chars[i] == "_" { i += 1 }
        return String(chars[start..<i]).lowercased()
    }

    /// A number with an optional unit (`%`, `deg`), or `none` (nil value).
    private mutating func number() throws -> (value: Double?, unit: String) {
        skipSpace()
        let start = i
        if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
        while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
        if i < chars.count, chars[i] == "e" || chars[i] == "E", i + 1 < chars.count, chars[i + 1].isNumber || chars[i + 1] == "-" || chars[i + 1] == "+" {
            i += 2
            while i < chars.count, chars[i].isNumber { i += 1 }
        }
        let digits = String(chars[start..<i])
        if digits.isEmpty || digits == "-" || digits == "+" {
            i = start
            if ident() == "none" { return (nil, "") }
            throw Failure()
        }
        guard let v = Double(digits) else { throw Failure() }
        let unitStart = i
        while i < chars.count, chars[i].isLetter || chars[i] == "%" { i += 1 }
        return (v, String(chars[unitStart..<i]).lowercased())
    }

    mutating func expression() throws -> ThemeCSSExpression {
        skipSpace()
        guard i < chars.count else { throw Failure() }
        if chars[i] == "#" {
            i += 1
            let start = i
            while i < chars.count, chars[i].isHexDigit { i += 1 }
            return .literal(try Self.hex(String(chars[start..<i])))
        }
        let name = ident()
        guard !name.isEmpty else { throw Failure() }
        if !eat("(") {
            switch name {
            case "transparent": return .literal(.transparent)
            case "black": return .literal(ThemeCSSColor(srgb: 0, 0, 0))
            case "white": return .literal(ThemeCSSColor(srgb: 1, 1, 1))
            default: throw Failure()
            }
        }
        switch name {
        case "var":
            skipSpace()
            let start = i
            while i < chars.count, chars[i] != ")" && chars[i] != "," { i += 1 }
            let variable = String(chars[start..<i]).trimmingCharacters(in: .whitespaces)
            try expect(")")
            return .variable(variable)
        case "color-mix":
            guard ident() == "in", let space = ThemeCSSColor.Space(rawValue: ident()) else { throw Failure() }
            try expect(",")
            let (a, p1) = try mixOperand()
            try expect(",")
            let (b, p2) = try mixOperand()
            try expect(")")
            return .mix(space, a, p1, b, p2)
        case "oklch", "oklab", "rgb", "rgba", "hsl", "hsla":
            var values: [(value: Double?, unit: String)] = []
            var alpha: (value: Double?, unit: String)?
            while !eat(")") {
                if eat(",") { continue }
                if eat("/") { alpha = try number(); continue }
                values.append(try number())
            }
            guard values.count == 3 || values.count == 4 && alpha == nil else { throw Failure() }
            if values.count == 4 { alpha = values.removeLast() }
            let a = alpha.map { ($0.value ?? 0) / ($0.unit == "%" ? 100 : 1) } ?? 1
            return .literal(try Self.color(name, values, alpha: min(max(a, 0), 1)))
        default:
            throw Failure()
        }
    }

    /// One `color-mix` operand: an expression with an optional percentage, which may be a `var()`.
    private mutating func mixOperand() throws -> (ThemeCSSExpression, ThemeCSSExpression.Percent?) {
        let color = try expression()
        skipSpace()
        guard i < chars.count, chars[i] != "," && chars[i] != ")" else { return (color, nil) }
        let save = i
        if ident() == "var", eat("(") {
            skipSpace()
            let start = i
            while i < chars.count, chars[i] != ")" { i += 1 }
            let variable = String(chars[start..<i]).trimmingCharacters(in: .whitespaces)
            try expect(")")
            return (color, .variable(variable))
        }
        i = save
        let n = try number()
        guard let v = n.value, n.unit == "%" else { throw Failure() }
        return (color, .value(v))
    }

    static func hex(_ h: String) throws -> ThemeCSSColor {
        let digits = h.count == 3 || h.count == 4 ? h.map { "\($0)\($0)" }.joined() : h
        guard digits.count == 6 || digits.count == 8, let v = UInt64(digits, radix: 16) else { throw Failure() }
        let n = digits.count == 8 ? v : v << 8 | 0xff
        func ch(_ shift: UInt64) -> Double { Double((n >> shift) & 0xff) / 255 }
        return ThemeCSSColor(srgb: ch(24), ch(16), ch(8), alpha: ch(0))
    }

    static func color(_ fn: String, _ v: [(value: Double?, unit: String)], alpha: Double) throws -> ThemeCSSColor {
        func pct(_ x: (value: Double?, unit: String), scale: Double) -> Double { (x.value ?? 0) * (x.unit == "%" ? scale / 100 : 1) }
        switch fn {
        case "oklch":
            return ThemeCSSColor(oklch: pct(v[0], scale: 1), pct(v[1], scale: 0.4), v[2].value, alpha: alpha)
        case "oklab":
            return ThemeCSSColor(lab: SIMD3(pct(v[0], scale: 1), pct(v[1], scale: 0.4), pct(v[2], scale: 0.4)), alpha: alpha)
        case "rgb", "rgba":
            return ThemeCSSColor(srgb: pct(v[0], scale: 255) / 255, pct(v[1], scale: 255) / 255, pct(v[2], scale: 255) / 255, alpha: alpha)
        default: // hsl
            let h = ((v[0].value ?? 0).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            let s = (v[1].value ?? 0) / 100, l = (v[2].value ?? 0) / 100
            func f(_ n: Double) -> Double {
                let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
                return l - s * min(l, 1 - l) * max(-1, min(k - 3, 9 - k, 1))
            }
            return ThemeCSSColor(srgb: f(0), f(8), f(4), alpha: alpha)
        }
    }
}
