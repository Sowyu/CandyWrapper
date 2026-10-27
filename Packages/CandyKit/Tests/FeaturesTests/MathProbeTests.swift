import AppKit
import Testing
@testable import Features

/// Renders the math corpus to a sheet for eyeballing: `CW_MATH_PROBE=/tmp/x.png scripts/test --filter MathProbeTests`.
@MainActor
struct MathProbeTests {
    @Test func sheet() throws {
        guard let path = ProcessInfo.processInfo.environment["CW_MATH_PROBE"] else { return }
        let range = (ProcessInfo.processInfo.environment["CW_MATH_PROBE_RANGE"] ?? "0-99").split(separator: "-").compactMap { Int($0) }
        let corpus = Array(MathCorpus.cases[min(range[0], MathCorpus.cases.count)..<min(range[1], MathCorpus.cases.count)])
        let scale: CGFloat = 2, width: CGFloat = 520, rowH: CGFloat = 70
        let height = rowH * CGFloat(corpus.count)
        let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
        ctx.translateBy(x: 0, y: height * scale); ctx.scaleBy(x: scale, y: -scale)
        for (i, c) in corpus.enumerated() {
            let y = CGFloat(i) * rowH + rowH / 2
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: CGFloat(i) * rowH, width: width, height: 0.5))
            guard let layout = MathRenderer.layout(c.tex, display: c.display, textSize: 14) else {
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                ("FALLBACK " + c.tex as NSString).draw(at: CGPoint(x: 10, y: y - 8), withAttributes: [.foregroundColor: NSColor.red])
                continue
            }
            let x = c.display ? (width - layout.width) / 2 : 40
            ctx.setFillColor(CGColor(red: 0.8, green: 0.9, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: x, y: y - layout.height, width: layout.width, height: layout.height + layout.depth))
            ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: x - 6, y: y, width: 4, height: 0.5))
            layout.draw(in: ctx, at: CGPoint(x: x, y: y), color: CGColor(gray: 0, alpha: 1))
        }
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}

extension MathProbeTests {
    /// Prints each corpus formula's box next to KaTeX's: `CW_MATH_METRICS=1 scripts/test --filter MathProbeTests`.
    @Test func metrics() throws {
        guard ProcessInfo.processInfo.environment["CW_MATH_METRICS"] != nil else { return }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../design/component-reference/math/metrics.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for c in MathCorpus.cases {
            let prefix = String(c.name.prefix(3))
            guard let key = json.keys.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".rest.light.png") }),
                  let f = (json[key] as? [String: Any])?["formula"] as? [String: Double] else { continue }
            guard let l = MathRenderer.layout(c.tex, display: c.display, textSize: 14) else { print("METRIC \(c.name) FALLBACK"); continue }
            let kw = f["width"]! - (c.display ? 0 : 0)
            print(String(format: "METRIC %@ w %.2f/%.2f h %.2f/%.2f d %.2f/%.2f", c.name, l.width, kw, l.height, f["height"]!, l.depth, f["depth"]!))
        }
    }
}

/// The formulas the KaTeX references cover (design/component-reference/math.json), in order.
enum MathCorpus {
    struct Case { let name: String; let tex: String; let display: Bool }
    static let cases: [Case] = [
        ("01-sup", "x^2", false), ("02-subsup", "x_i^2", false), ("03-frac", "\\frac{a}{b}", false), ("04-frac-display", "\\frac{a+b}{c-d}", true),
        ("05-sqrt", "\\sqrt{x}", false), ("06-root", "\\sqrt[3]{x+1}", true), ("07-greek", "\\alpha + \\beta = \\gamma", false),
        ("08-gamma", "\\Gamma(n) = (n-1)!", false), ("09-sum-display", "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}", true),
        ("10-sum-inline", "\\sum_{i=1}^{n} x_i", false), ("11-gaussian", "\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}", true),
        ("12-int-inline", "\\int_a^b f(x)\\,dx", false), ("13-prod", "\\prod_{k=1}^{n} k", true),
        ("14-lim", "\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1", true), ("15-emc2", "E = mc^2", false),
        ("16-relations", "a \\le b \\neq c \\approx d", false), ("17-leftright", "\\left( \\frac{a}{b} \\right)^2", true),
        ("18-pmatrix", "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", true),
        ("19-bmatrix", "\\begin{bmatrix} 1 & 0 & 0 \\\\ 0 & 1 & 0 \\\\ 0 & 0 & 1 \\end{bmatrix}", true),
        ("20-cases", "f(x) = \\begin{cases} x & x \\ge 0 \\\\ -x & x < 0 \\end{cases}", true),
        ("21-aligned", "\\begin{aligned} a &= b + c \\\\ d &= e \\end{aligned}", true),
        ("22-text", "\\text{if } x > 0 \\text{ then } y", false), ("23-accents", "\\hat{x} + \\bar{y} + \\vec{v} + \\tilde{n} + \\dot{a}", false),
        ("24-mathbb", "\\mathbb{R}^n \\to \\mathbb{R}", false), ("25-mathbf", "\\mathbf{v} \\cdot \\mathbf{w} = 0", false),
        ("26-quantifiers", "\\forall \\epsilon > 0, \\exists \\delta > 0", false), ("27-binom", "\\binom{n}{k} = \\frac{n!}{k!(n-k)!}", true),
        ("28-spaces", "a\\,b\\;c\\quad d\\qquad e", false), ("29-gauss-law", "\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\varepsilon_0}", true),
        ("30-quadratic", "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", true), ("31-overline", "\\overline{AB} \\perp \\mathcal{L}", false),
        ("32-norm", "\\| x \\|_2 = \\sqrt{\\sum_i x_i^2}", false), ("33-det", "\\det(A - \\lambda I) = 0", false),
        ("34-euler", "e^{i\\pi} + 1 = 0", true), ("35-set", "\\{ x \\in \\mathbb{Z} : x \\bmod 2 = 0 \\}", false),
    ].map { Case(name: $0.0, tex: $0.1, display: $0.2) }
}
