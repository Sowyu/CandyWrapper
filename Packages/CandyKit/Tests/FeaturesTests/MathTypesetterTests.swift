import AppKit
import Testing
@testable import Features

/// The native typesetter's reach, its fallback to TeX source as inline code, copying formulas and hostile input.
@MainActor
struct MathTypesetterTests {
    static func typesets(_ tex: String, display: Bool = false, size: CGFloat = 14) -> Bool {
        guard let l = MathRenderer.layout(tex, display: display, textSize: size) else { return false }
        return l.width.isFinite && l.width > 0 && l.height.isFinite && l.depth.isFinite
    }

    @Test func corpusTypesets() {
        for c in MathCorpus.cases {
            for size: CGFloat in [12, 14] {
                for display in [false, true] {
                    #expect(Self.typesets(c.tex, display: display, size: size), "\(c.name) size \(size) display \(display)")
                }
            }
        }
    }

    /// Formulas models write often, beyond the reference corpus.
    @Test func commonFormulasTypeset() {
        for tex in [
            "\\frac{\\partial f}{\\partial x}", "\\nabla^2 \\phi = 0", "\\sum_{n=0}^{\\infty} \\frac{x^n}{n!}", "a_1 + \\cdots + a_n",
            "\\mathcal{O}(n \\log n)", "\\operatorname{argmax}_x f(x)", "\\operatorname*{argmin}_{\\theta} L(\\theta)",
            "\\left\\{ x \\mid x > 0 \\right.", "\\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix}", "\\sum_{\\substack{i < j \\\\ i \\ne 0}} a_{ij}",
            "\\overbrace{a + b}^{n}", "\\underbrace{1 + \\cdots + 1}_{n}", "\\sqrt[n]{a^n}", "\\binom{n}{2}", "\\tfrac{1}{2}", "\\dfrac{a}{b}",
            "a \\not= b", "a \\equiv b \\pmod{n}", "\\begin{equation} E = mc^2 \\end{equation}",
            "\\begin{aligned} a &= b \\\\[4pt] c &= d \\end{aligned}", "\\boldsymbol{\\mu} + \\boldsymbol{+}", "f''(x) + f'(x)",
            "\\lim\\limits_{x \\to 0} f(x)", "\\int f(x) \\, \\mathrm{d}x", "x \\text{ if } x > 0", "P(A \\mid B) = \\frac{P(B \\mid A) P(A)}{P(B)}",
            "\\mathbb{E}[X] = \\mu", "\\sigma^2 = \\mathrm{Var}(X)", "\\vec{F} = m\\vec{a}", "\\hat{\\theta}_{\\text{MLE}}",
            "\\langle \\psi | \\phi \\rangle", "\\lfloor x \\rfloor + \\lceil y \\rceil", "A \\subseteq B \\cup C", "\\forall x \\in \\mathbb{R}",
            "e^{-\\frac{x^2}{2\\sigma^2}}", "\\prod_{i=1}^{n} p_i", "\\iint_D f \\, dA", "x \\to \\infty", "\\Delta t \\approx 0.1",
            "\\begin{bmatrix} x \\\\ y \\end{bmatrix}", "\\begin{smallmatrix} a & b \\\\ c & d \\end{smallmatrix}", "\\overline{z} \\cdot z = |z|^2",
            "\\begin{alignedat}{2} a &= b &\\quad c &= d \\end{alignedat}", "\\big( x \\big) + \\Bigg[ y \\Bigg]", "\\hspace{1em} x \\quad y",
            "\\color{red}{x} + y", "{\\color{#3366ff} a + b}", "\\textcolor{blue}{x}", "A \\xrightarrow{f} B", "A \\xleftarrow[g]{f} B",
            "\\cancel{x} + \\bcancel{y} + \\xcancel{z}", "\\begin{array}{c|c} a & b \\\\ \\hline c & d \\end{array}",
        ] {
            #expect(Self.typesets(tex) && Self.typesets(tex, display: true), "\(tex)")
        }
    }

    /// Beyond stage 1: the formula shows its source, never a crash or a blank.
    @Test func unsupportedFallsBack() {
        for tex in [
            "\\color{notacolor}{x}", "\\begin{matrix} a \\\\ \\hline b \\end{matrix}", "{x \\tag{1}}", "\\begin{array}{cx} a \\end{array}",
            "\\href{a}{b}", "\\unknowncommand", "a \\\\ b", "{x", "x}", "\\left( x", "\\begin{foo} x \\end{foo}", "x^^2", "x__2", "a & b",
            "\\frac{a}{", "\\sqrt[", "\\begin{matrix} a", "\\text{unclosed", "\\not\\alpha", "", "   ",
        ] {
            #expect(MathRenderer.layout(tex, display: false, textSize: 14) == nil, "\(tex)")
            #expect(MathRenderer.layout(tex, display: true, textSize: 14) == nil, "\(tex)")
        }
    }

    /// KaTeX takes `\tag` only in display math, at the top level.
    @Test func tagInDisplayOnly() {
        #expect(MathRenderer.layout("E = mc^2 \\tag{1}", display: true, textSize: 14)?.tag != nil)
        #expect(MathRenderer.layout("E = mc^2 \\tag{1}", display: false, textSize: 14) == nil)
        #expect(MathRenderer.layout("a \\tag{1} \\tag{2}", display: true, textSize: 14) == nil)
        #expect(MathRenderer.layout("x \\tag{1}^2", display: false, textSize: 14) == nil)
        #expect(MathRenderer.layout("\\color{red} x \\tag{1}", display: true, textSize: 14)?.tag != nil)
        let tagged = MarkdownLayout(document: MarkdownDocument(parsing: "$$E = mc^2 \\tag{1}$$", math: true), width: 480)
        #expect(Self.mathItems(tagged) == 2)
    }

    /// A reply streams character by character: every prefix lays out or falls back.
    @Test func everyPrefixIsSafe() {
        for c in MathCorpus.cases {
            var prefix = ""
            for ch in c.tex {
                prefix.append(ch)
                _ = MathRenderer.layout(prefix, display: c.display, textSize: 14)
            }
        }
    }

    @Test func hostileInputReturnsQuickly() {
        let matrixRow = Array(repeating: "1", count: 300).joined(separator: " & ")
        for (name, tex) in [
            ("nested braces", String(repeating: "{", count: 200) + "x" + String(repeating: "}", count: 200)),
            ("long sum", String(repeating: "x+", count: 10_000) + "x"),
            ("sqrt chain", String(repeating: "\\sqrt ", count: 5_000) + "x"),
            ("unbraced fracs", String(repeating: "\\frac1", count: 3_000) + "2"),
            ("big matrix", "\\begin{matrix}" + Array(repeating: matrixRow, count: 300).joined(separator: " \\\\ ") + "\\end{matrix}"),
        ] {
            let clock = ContinuousClock()
            let elapsed = clock.measure { _ = MathRenderer.layout(tex, display: true, textSize: 14) }
            #expect(elapsed < .seconds(2), "\(name) took \(elapsed)")
        }
    }

    // MARK: In Markdown

    static func inline(_ markdown: String) -> MarkdownStyle.Inline {
        guard case .paragraph(let runs)? = MarkdownDocument(parsing: markdown, math: true).blocks.first else { return MarkdownStyle.inline([], size: 14, color: .black) }
        return MarkdownStyle.inline(runs, size: 14, color: .black)
    }

    @Test func inlineFallbackIsCode() {
        let unsupported = Self.inline("see $\\foo{x}$ here")
        #expect(unsupported.formulas.isEmpty)
        let text = unsupported.string.string as NSString
        #expect(unsupported.code.map { text.substring(with: $0) } == ["\\(\\foo{x}\\)"])

        let supported = Self.inline("see $x^2$ here")
        #expect(supported.formulas.count == 1)
        #expect(supported.code.isEmpty)
        let range = supported.formulas[0].range
        #expect((supported.string.string as NSString).substring(with: range) == "\u{00A0}")
        #expect(supported.string.attribute(.markdownCopyText, at: range.location, effectiveRange: nil) as? String == "\\(x^2\\)")
    }

    static func mathItems(_ layout: MarkdownLayout) -> Int {
        layout.items.filter { if case .math = $0 { true } else { false } }.count
    }

    @Test func displayFallbackIsCode() {
        let fallback = MarkdownLayout(document: MarkdownDocument(parsing: "$$\\foo{x}$$", math: true), width: 480)
        #expect(Self.mathItems(fallback) == 0)
        let texts = fallback.items.compactMap { if case .text(let box, _) = $0 { box.text } else { nil } }
        #expect(texts.contains { $0.contains("\\[") && $0.contains("\\foo{x}") })

        let display = MarkdownLayout(document: MarkdownDocument(parsing: "$$x^2$$", math: true), width: 480)
        #expect(Self.mathItems(display) == 1)
        // Too wide for the column: it scrolls, with a scroller past every code block's index.
        let wide = MarkdownLayout(document: MarkdownDocument(parsing: "$$" + String(repeating: "a+", count: 200) + "a$$", math: true), width: 480)
        #expect(wide.items.contains { if case .scroll(let i, _, let w) = $0 { i >= 1_000_000 && w > 480 } else { false } })
    }

    /// An inline formula wider than the column is clipped to it, inside its own item.
    @Test func wideInlineFormulaIsClipped() {
        let layout = MarkdownLayout(document: MarkdownDocument(parsing: "see $" + String(repeating: "a+", count: 150) + "a$ here", math: true), width: 300)
        #expect(layout.items.contains { if case .math(_, _, _, let clip?) = $0 { clip.width <= 300 } else { false } })
    }

    @Test func copyGivesTeX() {
        let inline = Self.inline("a $x^2$ b")
        let box = MarkdownTextBox(inline.string, width: 480, lineHeight: MarkdownStyle.lineHeight, strut: MarkdownStyle.font(14),
                                  inlineBoxes: MarkdownMathStyle.inlineBoxes(inline, parent: MarkdownStyle.font(14), lineHeight: MarkdownStyle.lineHeight))
        #expect(box.copyText(NSRange(location: 0, length: (box.text as NSString).length)) == "a \\(x^2\\) b")
    }

    /// A tall inline formula grows its line, as a CSS line box grows around an inline-block; the next line moves down.
    @Test func tallFormulaGrowsItsLine() {
        let plain = MarkdownLayout(document: MarkdownDocument(parsing: "a b", math: true), width: 480)
        let tall = MarkdownLayout(document: MarkdownDocument(parsing: "a $\\displaystyle\\sum_{i=1}^{n} \\frac{a}{b}$ b", math: true), width: 480)
        #expect(tall.height > plain.height + 10)
    }

    @Test func settingOffKeepsText() {
        guard case .paragraph(let runs)? = MarkdownDocument(parsing: "$x_i$ and $y_i$").blocks.first else { Issue.record("no paragraph"); return }
        #expect(runs.allSatisfy { $0.math == nil })
    }
}
