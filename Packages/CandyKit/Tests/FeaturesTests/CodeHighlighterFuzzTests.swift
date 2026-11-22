import AppKit
import Foundation
import Testing
@testable import Features

/// Every lexer must return on any input, in time linear in its length. A lexer loop that stopped advancing froze the
/// app on launch (json() on `0-100`). These run each batch on a helper thread under a deadline, so a hang fails with
/// the input that caused it instead of hanging the suite.
/// The long version, with every pair of atoms and 50,000/200,000 unit inputs: `CW_FUZZ_LONG=1 scripts/test --filter Fuzz`.
struct CodeHighlighterFuzzTests {
    static let long = ProcessInfo.processInfo.environment["CW_FUZZ_LONG"] != nil

    /// Pieces the inputs are built from: every lexer's special characters and openers, with the common ones repeated
    /// so random strings hit them more often.
    static let atoms: [String] = {
        let singles = Array("\"'\\-$`{}<>/*#:;,.()[]=+!&|?@%~^_ \t\n\r0129xXaAfFrRbBeE").map(String.init)
        let unicode = ["é", "e\u{301}", "😀", "\u{feff}", "ß", "\u{200b}", "日"]
        let openers = ["${", "/*", "*/", "<!--", "-->", "//", "--", "@@", "+++", "---", "```", "~~~", "**", "](", "\"\"\"", "'''",
                       "f\"", "r'", "{{", "}}", "<<EOF", "<<-'EOF'", "EOF", "$(", "$((", "<?", "?>", "<![CDATA[", "]]>", "</",
                       "/>", "&amp;", "0x", "-1", "1e-", ".5", "=>", "->", "::", "#!", "@media", "!important", "--x", "\\u", "\\\n",
                       "key: ", "k = ", "[t]", "- ", "> ", "# ", "* ", "[a](b)", "fn", "def", "class", "function", "for", "in"]
        let common = ["\"", "'", "\\", "`", "-", "$", "{", "}", "\n", " ", "/", "*", "<", ">"]
        return singles + unicode + openers + common + common
    }()

    /// One snippet per lexer shape, truncated at every length below.
    static let snippets = [
        "const x = `a ${b + `c ${d}`} e` /re[/]g/i; // done\nfunction f(a, b) { return a <b> b }",
        "def f(x: int, *a) -> str:\n    return f\"{x!r} {{y}}\" + r'\\d' + '''doc\n'''  # c\n@dec\nclass A: pass",
        "#!/bin/sh\nfor i in $(seq 1 3); do echo \"${i}x $HOME\" 'q' >&2; done\ncat <<EOF\n$x\nEOF\nA=1 B=\"2\" cmd -f --flag",
        "{\"a\": -1.5e-3, \"b\": [true, null, \"x\\\"y\"], // c\n\"c\": {\"d\": 0-100}}",
        "a: [1, {b: c}, 'd']\n- e: f # g\n  h: |\n    i\nkey = \"v\"\n[table.sub]\nn = 1,2 ; c",
        "@media (x) { a:hover > .b #c { color: #fff; margin: -1.5em !important; --v: 2px; width: calc(1px + 2%) } }",
        "<!DOCTYPE html><a href=\"x\" b='y' c=d/><!-- c --><p>&amp; &#123; <b>x</b></p>",
        "--- a\n+++ b\n@@ -1,2 +1,3 @@ f\n-x\n+y\n context",
        "SELECT a, \"b\" FROM t WHERE x = 'y' -- c\n/* d */ AND n > 1;",
        "# H\n> q\n- **b** *i* _u_ `c` [l](u)\n```js\nx\n```\n~~~\ny",
    ]

    /// Inputs of `units` UTF-16 units each in the worst plausible shapes: many keys and short strings, deep
    /// nesting, one long line, one long unterminated string, and the patterns earlier lexers went quadratic on.
    static func shapes(_ units: Int) -> [String] {
        func fill(_ piece: String) -> String { String(repeating: piece, count: max(1, units / piece.utf16.count)) }
        return [
            fill("{\"id\": 12, \"name\": \"v\", \"ok\": true},\n"),
            fill("[{("),
            fill("a = b + c(d, \"e\") * 'f' / g; "),
            "\"" + fill("a"), "`" + fill("a"), "'" + fill("a"), "/*" + fill("a"),
            fill("`${"), "{" + fill("1"), "{" + fill("-"), fill("["), "[" + fill("a, "), "'' " + fill("x,"),
            fill("-"), fill("$"), fill("\\"), fill("<a "), fill("**x"), fill(" "), fill("\n"), fill("a: b\n"), fill("x \"y\" "),
        ]
    }

    /// Runs `work` on a helper thread with the main thread's stack size, and fails if it hasn't finished within
    /// `seconds`, naming the input it was on. The work reports its input through `current` before each call.
    static func withDeadline(_ seconds: Double, _ name: String, _ work: @escaping @Sendable (Current) -> Void) async {
        let current = Current()
        let finished = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let once = Once(done)
            let thread = Thread { work(current); once.resume(true) }
            thread.stackSize = 8 << 20
            thread.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.resume(false) }
        }
        if !finished {
            Issue.record("\(name) did not return within \(seconds) s on \(current.value.prefix(300).debugDescription) (\(current.value.utf16.count) units)")
        }
    }

    final class Current: @unchecked Sendable {
        private let lock = NSLock()
        private var input = ""
        var value: String { lock.withLock { input } }
        func set(_ s: String) { lock.withLock { input = s } }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done: CheckedContinuation<Bool, Never>?
        init(_ done: CheckedContinuation<Bool, Never>) { self.done = done }
        func resume(_ value: Bool) { lock.withLock { let d = done; done = nil; return d }?.resume(returning: value) }
    }

    /// A problem with `tokens` for `code`, or nil.
    static func problem(_ code: String, _ language: String) -> String? {
        let (tokens, stalls) = CodeHighlighter.lex(code, language: language)
        if stalls > 0 { return "a loop stopped advancing \(stalls) times" }
        let count = code.utf16.count
        var end = 0
        for t in tokens {
            if t.range.length <= 0 { return "empty token \(t.range)" }
            if t.range.location < end { return "token \(t.range) overlaps or is out of order after \(end)" }
            end = t.range.upperBound
            if end > count { return "token \(t.range) runs past the text's \(count) units" }
        }
        return nil
    }

    /// Text with lone surrogates, which a String bridged from an NSString can carry.
    static func loneSurrogates(_ prefix: String) -> String {
        let units = Array(prefix.utf16) + [0xd800, 0x22, 0xdc00, 0x60, 0xd83d]
        return NSString(characters: units, length: units.count) as String
    }

    static func inputs(seed: UInt64) -> [String] {
        var rng = SplitMix(seed: seed)
        var out = atoms
        if long { for a in atoms { for b in atoms { out.append(a + b) } } }
        else { for _ in 0..<1_500 { out.append(atoms[rng.next(atoms.count)] + atoms[rng.next(atoms.count)]) } }
        for _ in 0..<(long ? 4_000 : 1_000) {
            out.append((0..<(1 + rng.next(40))).map { _ in atoms[rng.next(atoms.count)] }.joined())
        }
        for snippet in snippets {
            let u = Array(snippet.utf16)
            for n in 0...u.count { out.append(String(decoding: u[0..<n], as: UTF16.self)) }
            out.append(loneSurrogates(snippet))
        }
        for a in atoms { out.append(String(repeating: a, count: long ? 2_000 : 300)) }
        return out
    }

    @Test func everyLexerReturnsOnArbitraryInput() async {
        let languages = CodeHighlighter.profileLanguages
        #expect(languages.count >= 15)
        #expect(languages.allSatisfy(CodeHighlighter.supports))
        let inputs = Self.inputs(seed: 0x5eed_c0de)
        await Self.withDeadline(Self.long ? 300 : 30, "a lexer") { current in
            for language in languages {
                for code in inputs {
                    current.set("[\(language)] " + code)
                    if let problem = Self.problem(code, language) {
                        Issue.record("\(language): \(problem) on \(code.prefix(200).debugDescription)")
                        return
                    }
                }
            }
        }
    }

    /// Lexing 4n units costs about 4 times n units, never 16. Times are summed over the shapes and the best of
    /// two runs taken, so one slow shape still moves the ratio while noise mostly cancels. `CW_FUZZ_PRINT=1` prints them.
    @Test func everyLexerIsLinear() async {
        let n = Self.long ? 50_000 : 2_500
        let small = Self.shapes(n), large = Self.shapes(4 * n)
        await Self.withDeadline(Self.long ? 300 : 30, "a timed lexer") { current in
            let clock = ContinuousClock()
            func time(_ inputs: [String], _ language: String) -> Double {
                var best = Double.infinity
                for _ in 0..<2 {
                    var total = Duration.zero
                    for code in inputs {
                        current.set("[\(language)] " + code)
                        total += clock.measure { _ = CodeHighlighter.tokens(code, language: language) }
                    }
                    best = min(best, Double(total.components.attoseconds) / 1e18 + Double(total.components.seconds))
                }
                return best
            }
            for language in CodeHighlighter.profileLanguages {
                var ratio = time(large, language) / max(time(small, language), 1e-4)
                // Other suites run beside this one, so a slow reading is measured once more before it counts.
                if ratio >= 6 { ratio = min(ratio, time(large, language) / max(time(small, language), 1e-4)) }
                if ProcessInfo.processInfo.environment["CW_FUZZ_PRINT"] != nil { print("ratio \(language) \(ratio)") }
                #expect(ratio < 6, "\(language): 4n took \(ratio)x as long as n")
                // Name the shape that went quadratic.
                if ratio >= 6 {
                    for (a, b) in zip(small, large) {
                        let r = time([b], language) / max(time([a], language), 1e-5)
                        if r >= 8 { Issue.record("\(language): \(r)x on \(a.prefix(40).debugDescription)") }
                    }
                }
            }
        }
    }

    /// A chat code block colors only its first 30,000 units, up to a line break, so one block can't hold the main
    /// thread for long. Shorter blocks color in full.
    @Test func longBlocksColorOnlyTheirStart() {
        let line = "let x = 1 // c\n"
        #expect(CodeHighlighter.highlightedPrefix(line) == line)
        let code = String(repeating: line, count: 4_000)
        let head = CodeHighlighter.highlightedPrefix(code)
        #expect(head.utf16.count == 30_014 && code.hasPrefix(head) && head.hasSuffix("// c"))
        #expect(CodeHighlighter.highlightedPrefix(String(repeating: "a", count: 40_000)).utf16.count == 30_000)
    }

    /// Every `\(` with no `\)` after it rescanned the rest of its paragraph: 16,000 units took 4 s.
    @Test func mathOpenersWithoutClosersParseInLinearTime() {
        let clock = ContinuousClock()
        func seconds(_ units: Int) -> Double {
            let markdown = String(repeating: "\\(", count: units / 2)
            let d = clock.measure { _ = MarkdownDocument(parsing: markdown, math: true) }
            return Double(d.components.attoseconds) / 1e18 + Double(d.components.seconds)
        }
        let small = min(seconds(4_000), seconds(4_000)), large = min(seconds(16_000), seconds(16_000))
        #expect(large / small < 7, "\(large / small)x")
    }

    /// The same for the Markdown parser and layout every message goes through.
    @Test func markdownReturnsOnArbitraryInput() async {
        let atoms = ["*", "_", "`", "```", "~~~", "[", "]", "(", ")", "!", "#", "> ", "- ", "+ ", "1. ", "|", "|---|", "$", "$$",
                     "\\(", "\\)", "\\[", "\\]", "\\", "<", ">", "<details>", "</details>", "<br>", "&amp;", ":", "~~", "\n", "\n\n",
                     " ", "    ", "\t", "http://a.b/c", "<http://x>", "/tmp/a.swift:12", "src/a.ts#L3", "@a/b.md", "[^1]", "[^1]: n",
                     "- [ ] ", "> [!NOTE]\n", "---\n", "***", "=", "e\u{301}", "😀", "a", "1", "{", "}", "^", "\\frac{a}{b}"]
        var rng = SplitMix(seed: 0xfeed_beef)
        var inputs = atoms
        for _ in 0..<(Self.long ? 3_000 : 400) {
            inputs.append((0..<(1 + rng.next(30))).map { _ in atoms[rng.next(atoms.count)] }.joined())
        }
        if Self.long { for a in atoms { for b in atoms { inputs.append(a + b) } } }
        for a in atoms { inputs.append(String(repeating: a, count: Self.long ? 2_000 : 200)) }
        inputs.append("```json\n{\"vibrate\": 0-100}\n```")
        let all = inputs
        await Self.withDeadline(Self.long ? 600 : 60, "Markdown") { current in
            for markdown in all {
                current.set(markdown)
                for math in [false, true] {
                    let document = MarkdownDocument(parsing: markdown, math: math)
                    _ = MarkdownLayout(document: document, width: 400)
                }
            }
        }
    }
}
