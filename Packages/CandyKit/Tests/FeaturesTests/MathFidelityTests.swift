import AppKit
import Testing
import DesignSystem
@testable import Features

/// Formulas in MarkdownView against T3's KaTeX 0.16.47 output with T3's stylesheet in Chromium, at 1x and 2x
/// (spec from scripts/gen-math-spec, references in design/component-reference/math). The fonts differ (Latin Modern
/// Math against KaTeX's Computer Modern), so the ceilings allow for glyph edges; boxes and positions must match.
/// Writes ref, ours and diff PNGs plus `Fidelity.root`/report-math.html.
@MainActor @Suite(.fidelity)
struct MathFidelityTests {
    /// Measured 2026-10-27 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "math": .init(0.06, except: [
            "01-power.dark@1x": 0.07,
            "02-scripts.dark@1x": 0.10,
            "02-scripts.dark@2x": 0.07,
            "02-scripts.light@1x": 0.09,
            "02-scripts.light@2x": 0.07,
            "03-inline-fraction.dark@1x": 0.09,
            "03-inline-fraction.light@1x": 0.08,
            "05-square-root.dark@1x": 0.12,
            "05-square-root.light@1x": 0.12,
            "07-greek.dark@1x": 0.10,
            "07-greek.light@1x": 0.07,
            "08-gamma.dark@1x": 0.11,
            "08-gamma.dark@2x": 0.07,
            "08-gamma.light@1x": 0.09,
            "08-gamma.light@2x": 0.07,
            "10-inline-sum.dark@1x": 0.13,
            "10-inline-sum.dark@2x": 0.08,
            "10-inline-sum.light@1x": 0.09,
            "10-inline-sum.light@2x": 0.07,
            "12-inline-integral.dark@1x": 0.16,
            "12-inline-integral.dark@2x": 0.11,
            "12-inline-integral.light@1x": 0.15,
            "12-inline-integral.light@2x": 0.11,
            "15-energy.dark@1x": 0.15,
            "15-energy.light@1x": 0.14,
            "16-relations.dark@1x": 0.11,
            "16-relations.dark@2x": 0.07,
            "16-relations.light@1x": 0.09,
            "16-relations.light@2x": 0.07,
            "22-text.dark@1x": 0.13,
            "22-text.dark@2x": 0.08,
            "22-text.light@1x": 0.12,
            "22-text.light@2x": 0.08,
            "23-accents.dark@1x": 0.15,
            "23-accents.dark@2x": 0.10,
            "23-accents.light@1x": 0.12,
            "23-accents.light@2x": 0.09,
            "24-blackboard.dark@1x": 0.17,
            "24-blackboard.dark@2x": 0.12,
            "24-blackboard.light@1x": 0.16,
            "24-blackboard.light@2x": 0.11,
            "25-bold.dark@1x": 0.09,
            "25-bold.light@1x": 0.07,
            "26-quantifiers.dark@1x": 0.18,
            "26-quantifiers.dark@2x": 0.14,
            "26-quantifiers.light@1x": 0.17,
            "26-quantifiers.light@2x": 0.14,
            "28-spacing.dark@1x": 0.09,
            "28-spacing.light@1x": 0.09,
            "31-overline.dark@1x": 0.12,
            "31-overline.dark@2x": 0.08,
            "31-overline.light@1x": 0.10,
            "31-overline.light@2x": 0.09,
            "32-norm.dark@1x": 0.18,
            "32-norm.dark@2x": 0.09,
            "32-norm.light@1x": 0.17,
            "32-norm.light@2x": 0.08,
            "33-determinant.dark@1x": 0.12,
            "33-determinant.dark@2x": 0.07,
            "33-determinant.light@1x": 0.10,
            "33-determinant.light@2x": 0.07,
            "35-set.dark@1x": 0.17,
            "35-set.dark@2x": 0.13,
            "35-set.light@1x": 0.15,
            "35-set.light@2x": 0.12,
        ]),
    ]
    static let repo = MarkdownFidelityTests.repo

    /// T3's three paragraph cases put each formula in this text (scripts/gen-math-spec.cjs).
    static let paragraphs = [
        "36-paragraph-energy": "Energy is $E = mc^2$ here.",
        "37-paragraph-fraction": "The ratio $\\frac{a}{b}$ grows.",
        "38-paragraph-sum": "Sum $\\sum_{i=1}^{n} x_i$ ends.",
    ]

    static func markdown(_ c: [String: Any]) -> String? {
        let name = c["name"] as! String, tex = c["tex"] as! String
        if let p = paragraphs[name] { return p }
        // The fallback is CandyWrapper's code style by the user's choice, not T3's plain text; MathFallbackTests covers it.
        guard name != "39-fallback" else { return nil }
        return c["display"] as? Bool == true ? "$$\(tex)$$" : "$\(tex)$"
    }

    @Test func math() throws {
        let refDir = Self.repo.appendingPathComponent("design/component-reference/math")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("design/component-reference/math.json"))) as! [String: Any]
        let dir = Fidelity.root.appendingPathComponent("math")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rows = "", cases: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            guard let markdown = Self.markdown(c) else { continue }
            for theme in ["light", "dark"] {
                for scale in [1, 2] {
                    let file = "\(name).rest.\(theme)\(scale == 2 ? "@2x" : "").png"
                    let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent(file))))
                    let view = MarkdownView(frame: .zero)
                    view.document = MarkdownDocument(parsing: markdown, math: true)
                    let width: CGFloat = 480
                    let height = view.height(forWidth: width)
                    let canvas = MarkdownFidelityTests.Canvas(frame: .zero)
                    canvas.addSubview(view)
                    view.frame = NSRect(x: 8, y: 8, width: width, height: height)
                    let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / CGFloat(scale), height: CGFloat(ref.pixelsHigh) / CGFloat(scale)),
                                              scale: CGFloat(scale), dark: theme == "dark")
                    let (share, diff) = MarkdownFidelityTests.compare(ref, ours)
                    let base = "\(name).\(theme)@\(scale)x"
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).ref.png"))
                    try FileManager.default.copyItem(at: refDir.appendingPathComponent(file), to: dir.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: dir.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: dir.appendingPathComponent("\(base).diff.png"))
                    print(String(format: "MATH %@: %.2f%% differ", base, share * 100))
                    cases.append((base, share))
                    rows += "<tr><td>\(base) \(String(format: "%.1f%%", share * 100))</td>"
                        + ["ref", "ours", "diff"].map { "<td><img src='math/\(base).\($0).png'></td>" }.joined() + "</tr>"
                }
            }
        }
        print(String(format: "FIDELITY Math: %d cases, mean differing %.2f%%", cases.count, cases.map(\.1).reduce(0, +) / Double(max(cases.count, 1)) * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Math fidelity</title><style>body{font:13px -apple-system}td{vertical-align:top}</style>"
            + "<p>KaTeX in Chromium, ours, diff.</p><table>\(rows)</table>"
        try html.write(to: Fidelity.root.appendingPathComponent("report-math.html"), atomically: true, encoding: .utf8)
        Self.ceilings.check("math", cases)
    }
}
