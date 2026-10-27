import Foundation
import Testing
@testable import Features

/// T3's chat math parsing (shared/src/markdownMath.test.ts), case by case, through `MarkdownDocument(math: true)`.
/// A display formula here takes a block of its own, so text next to one loses the spaces at the split.
struct MarkdownMathParserTests {
    private static func parse(_ markdown: String) -> [MarkdownBlock] { MarkdownDocument(parsing: markdown, math: true).blocks }

    /// Every run and every math block, in document order.
    private static func walk(_ blocks: [MarkdownBlock], run: (InlineRun) -> Void, math: (MarkdownMath) -> Void) {
        for block in blocks {
            switch block {
            case .paragraph(let runs), .heading(_, let runs): runs.forEach(run)
            case .list(let list): list.items.forEach { walk($0.blocks, run: run, math: math) }
            case .blockquote(let children), .alert(_, let children): walk(children, run: run, math: math)
            case .table(let table): ([table.header] + table.rows).forEach { $0.forEach { $0.forEach(run) } }
            case .math(let formula): math(formula)
            case .code, .rule, .image: break
            }
        }
    }

    /// Formulas as `[kind, tex]`, like T3's `formulas()`; `$$…$$` and `\[…\]` are display wherever they stand.
    private static func formulas(_ markdown: String) -> [[String]] {
        var out: [[String]] = []
        func add(_ m: MarkdownMath) { out.append([m.display ? "display" : "inline", m.tex]) }
        walk(parse(markdown), run: { if let m = $0.math { add(m) } }, math: add)
        return out
    }

    /// The prose, like T3's `text()`: no code, no formulas, a soft break as the line ending it was.
    private static func text(_ markdown: String) -> String {
        var out = ""
        walk(parse(markdown), run: { run in
            guard run.math == nil, !run.code else { return }
            out += run.isBreak ? "\n" : run.text
        }, math: { _ in })
        return out
    }

    private static func runs(_ markdown: String) -> [InlineRun] {
        var out: [InlineRun] = []
        walk(parse(markdown), run: { out.append($0) }, math: { _ in })
        return out
    }

    private static func display(_ tex: String) -> MarkdownBlock { .math(MarkdownMath(tex: tex, display: true)) }

    // MARK: chat math parsing

    /// "keeps GFM autolink destinations intact while restoring literal dollars"
    @Test func autolinkDestinationsKeepDollars() {
        let source = "Query www.example.com/?$select=id and $x$."
        #expect(Self.formulas(source) == [["inline", "x"]])
        #expect(Self.runs(source).contains { $0.link?.absoluteString.hasSuffix("www.example.com/?$select=id") == true })
    }

    /// "parses formulas without reserving private-use characters"
    @Test func privateUseCharactersStayText() {
        let characters = String((0..<6400).map { Character(UnicodeScalar(0xE000 + $0)!) })
        let source = "$x$ " + characters
        #expect(Self.formulas(source) == [["inline", "x"]])
        #expect(Self.text(source) == " " + characters)
    }

    /// "preserves indented code containing %s"
    @Test(arguments: ["\\(x\\)", "$x$", "$$x$$"]) func indentedCodeKeepsFormulas(formula: String) {
        #expect(Self.parse("    " + formula) == [.code(language: "text", title: nil, code: formula)])
    }

    /// "only exposes closed explicit math fences to editors and native rendering"
    @Test func onlyClosedMathFencesAreMath() {
        #expect(Self.parse("```math\nx^2") == [.code(language: "math", title: nil, code: "x^2")])
        #expect(Self.parse("```math\nx^2\n```") == [Self.display("x^2")])
        #expect(Self.parse("> ```math\n> x^2\n> ```") == [.blockquote([Self.display("x^2")])])
        #expect(Self.parse("~~~math title=\"Energy\"\nE = mc^2\n~~~") == [Self.display("E = mc^2")])
    }

    /// "reads the four delimiters models emit"
    @Test func readsTheFourDelimiters() {
        #expect(Self.formulas("Inline $x^2$ and \\(y_1\\), display $$a+b$$ and \\[c\\].") == [
            ["inline", "x^2"], ["inline", "y_1"], ["display", "a+b"], ["display", "c"],
        ])
    }

    /// "reads display blocks on their own lines"
    @Test func readsDisplayBlocks() {
        #expect(Self.formulas("$$\n\\frac{a}{b}\n$$") == [["display", "\\frac{a}{b}"]])
        let aligned = "\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}"
        #expect(Self.parse("Where\n\\[\n\(aligned)\n\\]\nholds.") == [
            .paragraph([InlineRun(text: "Where")]), Self.display(aligned), .paragraph([InlineRun(text: "holds.")]),
        ])
    }

    /// "keeps text after a same-line formula separate from later display math: %s"
    @Test(arguments: [" is the first formula.", ", followed by prose.", " \tthen more text."])
    func textAfterSameLineFormula(trailing: String) {
        let source = "$$a$$\(trailing)\nSome prose.\n$$\nb\n$$"
        let blocks = Self.parse(source)
        #expect(blocks.count == 3)
        #expect(blocks.first == Self.display("a"))
        #expect(blocks.last == Self.display("b"))
        #expect(Self.text(source) == trailing.trimmingCharacters(in: .whitespaces) + "\nSome prose.")
    }

    /// "keeps block syntax inside display blocks as TeX"
    @Test func blockSyntaxInsideDisplayIsTeX() {
        #expect(Self.formulas("\\[\nx\n- y\n# z\n\\]\nafter") == [["display", "x\n- y\n# z"]])
        #expect(Self.parse("> $$\n> x\n> $$") == [.blockquote([Self.display("x")])])
        // Same-line content is not a fence; it stays one formula.
        #expect(Self.formulas("$$x^2\n+y^2$$") == [["display", "x^2\n+y^2"]])
        #expect(Self.text("$$E=mc^2") == "$$E=mc^2")
    }

    /// "keeps prices, shell variables, and skill tokens as prose"
    @Test(arguments: [
        "It costs $5 and $10.", "Budget $5-$10 per seat, or $20,000-$30,000 a year.", "Plans are $5/$10 monthly.",
        "Run $browser then $deploy on it.", "Set $HOME before running.",
    ]) func pricesStayProse(prose: String) {
        #expect(Self.formulas(prose) == [])
        #expect(Self.text(prose) == prose)
    }

    /// "keeps prices as prose when math follows on the same line"
    @Test(arguments: ["$5-$10", "$5 and $10", "$5/$10", "$20,000-$30,000"]) func pricesBeforeMath(price: String) {
        let source = "Price \(price) stays literal. The formula is $x_i$ and $5$."
        #expect(Self.formulas(source) == [["inline", "x_i"], ["inline", "5"]])
        #expect(Self.text(source) == "Price \(price) stays literal. The formula is  and .")
    }

    /// "leaves code, escapes, links, and citations alone"
    @Test(arguments: [
        ("Use `$x$` in code.", "Use  in code."),
        ("It costs $5 and $10, and `$HOME` stays code.", "It costs $5 and $10, and  stays code."),
        ("Export $PATH, then `$HOME`.", "Export $PATH, then ."),
        ("\\(a `\\)` b", "(a  b"),
        ("Set $TOKEN, then open [users](https://graph.microsoft.com/v1.0/users?$select=id).", "Set $TOKEN, then open users."),
        ("Set $TOKEN, then open <https://graph.microsoft.com/v1.0/users?$select=id>.",
         "Set $TOKEN, then open https://graph.microsoft.com/v1.0/users?$select=id."),
        ("```\n$x$ \\(y\\)\n```", ""),
        ("Escaped \\$x\\$ stays.", "Escaped $x$ stays."),
        ("Escaped \\\\(x\\\\) stays.", "Escaped \\(x\\) stays."),
        ("See [docs](https://example.com/\\(a\\)) here.", "See docs here."),
        ("As shown in \\[1\\] and \\[2, 3\\].", "As shown in [1] and [2, 3]."),
    ]) func codeEscapesLinksAndCitations(markdown: String, rendered: String) {
        #expect(Self.formulas(markdown) == [])
        #expect(Self.text(markdown) == rendered)
    }

    /// "starts a formula right after an escaped dollar"
    @Test func formulaAfterEscapedDollar() {
        #expect(Self.formulas("Pay \\$$x$ now.") == [["inline", "x"]])
        #expect(Self.text("Pay \\$$x$ now.") == "Pay $ now.")
    }

    /// "preserves an adjacent code span in %s"
    @Test(arguments: [("$a`$HOME`", "$HOME"), ("\\(a`\\)`", "\\)"), ("\\(a\\alpha`\\)`", "\\)"), ("text \\[a`\\]`", "\\]")])
    func adjacentCodeSpan(source: String, code: String) {
        #expect(Self.formulas(source) == [])
        #expect(Self.runs(source).contains { $0.code && $0.text == code })
    }

    /// "respects %i backslashes before a display fence"
    @Test(arguments: [1, 2]) func backslashesBeforeDisplayFence(count: Int) {
        let prefix = "a+" + String(repeating: "\\", count: count)
        for opening in ["$$", "$$\n"] {
            let source = "\(opening)\(prefix)$$\nb\n$$"
            #expect(Self.formulas(source) == [["display", count % 2 == 1 ? "\(prefix)$$\nb" : prefix]], "\(source)")
        }
    }

    /// "keeps TeX escapes inside formulas"
    @Test func texEscapesInsideFormulas() {
        #expect(Self.formulas("Cost $a\\$b$ and \\(\\left(x\\right)\\).") == [["inline", "a\\$b"], ["inline", "\\left(x\\right)"]])
    }

    /// "keeps source offsets of the original message" and "keeps authored lines and UTF-16 offsets with %j": the
    /// offsets have no equivalent here; the formulas, their line endings and the task items do.
    @Test(arguments: ["\n", "\r\n", "\r"]) func lineEndingsInFormulas(eol: String) {
        let source = "😀 \\(x\(eol)+y\\)\(eol)\(eol)- [ ] check $z$"
        #expect(Self.formulas(source) == [["inline", "x\(eol)+y"], ["inline", "z"]])
        guard case .list(let list)? = Self.parse(source).last else { Issue.record("no list"); return }
        #expect(list.items.first?.task == false)
        #expect(Self.formulas("- [ ] check \\(x\\)\n- [x] then $y$") == [["inline", "x"], ["inline", "y"]])
    }

    /// "shows unfinished formulas as text while a response streams"
    @Test func unfinishedFormulasStayText() {
        let message = "Energy \\(E = mc^2\\) and $$\\sum_i x_i$$ done."
        var end = message.startIndex
        while true {
            _ = Self.parse(String(message[..<end]))
            if end == message.endIndex { break }
            end = message.index(after: end)
        }
        #expect(Self.text("Energy \\(E = mc") == "Energy (E = mc")
        #expect(Self.formulas("$$\nx^2") == [])
        #expect(Self.formulas("\\[\nx^2\n- y") == [])
        #expect(Self.formulas(message) == [["inline", "E = mc^2"], ["display", "\\sum_i x_i"]])
    }

    // MARK: math in GFM tables

    private static func table(_ markdown: String) -> MarkdownTable? {
        if case .table(let table)? = parse(markdown).first { return table }
        return nil
    }

    /// "renders math in link labels while retaining dollars in their destinations"
    @Test func mathInLinkLabels() {
        let row = "| [norm $|x|$](https://example.com/$path) | y$ |"
        for source in ["\(row)\n| --- | --- |", "| First | Second |\n| --- | --- |\n\(row)"] {
            let table = Self.table(source)
            #expect(table?.alignments.count == 2, "\(source)")
            #expect(Self.formulas(source) == [["inline", "|x|"]])
            #expect(Self.runs(source).contains { $0.link?.absoluteString == "https://example.com/$path" })
        }
    }

    /// "preserves table separators after literal dollars in %s"
    @Test(arguments: ["[a](https://example.com/$x)", "`$x`", "<span title=\"$x\">a</span>"])
    func literalDollarsKeepSeparators(literal: String) {
        let row = "| \(literal) | y$ |"
        for source in ["\(row)\n| --- | --- |", "| First | Second |\n| --- | --- |\n\(row)"] {
            let table = Self.table(source)
            #expect(table?.alignments.count == 2, "\(source)")
            #expect(table.map { ([$0.header] + $0.rows).allSatisfy { $0.count == 2 } } == true)
            #expect(Self.formulas(source) == [])
        }
    }

    /// "retains multiline math after a prose pipe outside tables"
    @Test func multilineMathAfterProsePipe() {
        #expect(Self.formulas("a | b: \\(x\n+y\\)") == [["inline", "x\n+y"]])
    }

    /// "keeps table rows intact when %s closes in a later row"
    @Test(arguments: ["\\(", "\\["]) func formulaClosingInLaterRow(opener: String) {
        let closer = opener == "\\(" ? "\\)" : "\\]"
        let source = "| Name | Value |\n| --- | --- |\n| first | \(opener)x |\n| second | y\(closer) |\n| valid | $|z|$ |"
        let table = Self.table(source)
        #expect(table?.rows.count == 3)
        #expect(Self.text(source) == "NameValuefirst\(opener.dropFirst())xsecondy\(closer.dropFirst())valid")
        #expect(Self.formulas(source) == [["inline", "|z|"]])
    }

    /// "keeps pipes inside %s in one cell and preserves source offsets"
    @Test(arguments: [("\\(\\frac{1}{|x|}\\)", ["inline", "\\frac{1}{|x|}"]), ("$$|x|$$", ["display", "|x|"]), ("$|x|$", ["inline", "|x|"])])
    func pipesInsideFormulaStayInOneCell(formula: String, expected: [String]) {
        let source = "| Name | Value |\n| --- | --- |\n| x | \(formula) |\n\n- [ ] next"
        let table = Self.table(source)
        #expect(table?.rows.count == 1)
        #expect(table?.rows.first?.count == 2)
        #expect(table?.rows.first?.last?.first?.math?.tex == expected[1])
        #expect(Self.formulas(source) == [expected])
        guard case .list(let list)? = Self.parse(source).last else { Issue.record("no list"); return }
        #expect(list.items.first?.task == false)
    }

    /// "preserves TeX pipe commands inside and outside tables"
    @Test func texPipeCommands() {
        #expect(Self.formulas("| Formula |\n| --- |\n| \\(\\|x\\|\\) |\n\n\\(\\|x\\|\\)") == [["inline", "\\|x\\|"], ["inline", "\\|x\\|"]])
    }

    /// "leaves code, URLs, incomplete math, and private-use text unchanged"
    @Test func codeURLsAndIncompleteMathInTables() {
        let source = "| Value | Other |\n| --- | --- |\n| `\\(a\\|b\\)` | \\(x|y\\) |\n\n\u{E000}\n\n[link](https://example.com/$x|y$)\n\nUnclosed \\(x|y"
        #expect(Self.formulas(source) == [["inline", "x|y"]])
        let runs = Self.runs(source)
        #expect(runs.contains { $0.link?.absoluteString.contains("example.com/$x%7Cy$") == true || $0.link?.absoluteString == "https://example.com/$x|y$" })
        #expect(runs.contains { $0.text == "\u{E000}" })
        #expect(Self.text(source).hasSuffix("Unclosed (x|y"))
    }

    /// "keeps a display equation's equality line out of Markdown headings"
    @Test func equalityLineStaysTeX() {
        #expect(Self.parse("\\[\na\n=\nb\n\\]") == [Self.display("a\n=\nb")])
    }

    // MARK: CandyWrapper's blocks

    @Test func inlineRunsHoldTheCopySource() {
        let runs = Self.runs("**Energy** $E=mc^2$ and \\(x\\)")
        let math = runs.filter { $0.math != nil }
        #expect(math.map(\.text) == ["\\(E=mc^2\\)", "\\(x\\)"])
        #expect(math.allSatisfy { !$0.bold && !$0.italic && !$0.code && $0.link == nil })
    }

    @Test func displayFormulaSplitsItsParagraph() {
        #expect(Self.parse("Text $$a$$ more") == [
            .paragraph([InlineRun(text: "Text")]), Self.display("a"), .paragraph([InlineRun(text: "more")]),
        ])
        #expect(Self.parse("\\[x\\]") == [Self.display("x")])
    }

    @Test func displayMathInContainers() {
        let list = Self.parse("- item\n  $$\n  x\n  $$\n- next $y$")
        guard case .list(let l)? = list.first else { Issue.record("no list"); return }
        #expect(l.items.first?.blocks == [.paragraph([InlineRun(text: "item")]), Self.display("x")])
        #expect(Self.parse("- $$\n  x\n  $$") == [.list(MarkdownList(ordered: false, start: 1, items: [MarkdownListItem(task: nil, blocks: [Self.display("x")])]))])
        guard case .alert(.note, let children)? = Self.parse("> [!NOTE]\n> See $x$.").first else { Issue.record("no alert"); return }
        #expect(children.count == 1)
        #expect(Self.formulas("# Title $x$\n\n> quote \\(y\\)") == [["inline", "x"], ["inline", "y"]])
        // A lazy line ends a display block in a quote, so it never closes.
        #expect(Self.formulas("> $$\nx\n> $$") == [])
    }

    @Test func windowsPathsKeepTheirEscapesAndFormulasTheirTeX() {
        let source = "Open C:\\Users\\me\\.t3 and $C:\\.x$"
        #expect(Self.formulas(source) == [["inline", "C:\\.x"]])
        #expect(Self.text(source) == "Open C:\\Users\\me\\.t3 and ")
    }

    @Test func mathOffLeavesTheText() {
        for source in ["Inline $x^2$ and \\(y\\)", "$$\nx\n$$", "```math\nx^2\n```", "| a | $|x|$ |\n| - | - |"] {
            let off = MarkdownDocument(parsing: source)
            #expect(off == MarkdownDocument(parsing: source, math: false))
            var hasMath = false
            Self.walk(off.blocks, run: { if $0.math != nil { hasMath = true } }, math: { _ in hasMath = true })
            #expect(!hasMath, "\(source)")
        }
        #expect(MarkdownDocument(parsing: "Inline $x^2$ here").blocks == [.paragraph([InlineRun(text: "Inline $x^2$ here")])])
    }

    @Test func textWithoutMathParsesAsBefore() {
        for source in ["Plain **text** with `code`.", "Costs $5 and $10.", "```swift\nlet x = 1\n```"] {
            #expect(MarkdownDocument(parsing: source, math: true) == MarkdownDocument(parsing: source), "\(source)")
        }
        #expect(!MarkdownMathScanner.mayContainMath(Substring("Plain text, no math (here) [x]").utf8))
        #expect(MarkdownMathScanner.mayContainMath(Substring("```  math\nx").utf8))
        #expect(!MarkdownMathScanner.mayContainMath(Substring("```mathematica\nx").utf8))
    }
}
