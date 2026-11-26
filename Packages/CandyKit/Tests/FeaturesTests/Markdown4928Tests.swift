import AppKit
import Testing
import DesignSystem
@testable import Features

/// Nightly 4928 chat Markdown changes (docs/research/nightly-diff-4928.md, 1.5).
@MainActor
struct Markdown4928Tests {
    private func parse(_ text: String) -> [MarkdownBlock] {
        MarkdownDocument(parsing: MarkdownDocument.rewritingInsights(text), preservesLineBreaks: true).blocks
    }

    /// #22239: an insight block between `★ Insight ───` and `───` is an insight callout.
    @Test func insightBlockBecomesACallout() {
        let blocks = parse("Before.\n\n`★ Insight ─────────────────────`\n- One point\n- Two\n`─────────────────────────────────`\n\nAfter.")
        #expect(blocks.count == 3)
        guard case .alert(.insight, let children) = blocks[1] else { Issue.record("no insight: \(blocks)"); return }
        guard case .list = children.first else { Issue.record("no list: \(children)"); return }
        #expect(blocks[2] == .paragraph([InlineRun(text: "After.")]))
    }

    @Test func insightMarkerInsideCodeOrQuotesStaysText() {
        let fenced = "```\n★ Insight ─────\nx\n─────\n```"
        #expect(MarkdownDocument.rewritingInsights(fenced) == fenced)
        let quoted = "> ★ Insight ─────\n> x"
        #expect(MarkdownDocument.rewritingInsights(quoted) == quoted)
        let plain = "No marker here ─────"
        #expect(MarkdownDocument.rewritingInsights(plain) == plain)
        // A written alert with the word never becomes one.
        guard case .blockquote = MarkdownDocument(parsing: "> [!insight]\n> x").blocks.first else { Issue.record("written insight alert"); return }
    }

    /// T3's own cases (shared/src/markdownPipeline.test.ts:302-345 at 4928): both fence forms open a callout, and
    /// literal or nested examples stay as written.
    @Test func insightFencesMatchT3Cases() {
        let rule = String(repeating: "─", count: 20)
        func fence(_ body: String, _ wrap: String = "") -> String { ["\(wrap)★ Insight \(rule)\(wrap)", body, "\(wrap)\(rule)\(wrap)"].joined(separator: "\n") }
        for wrap in ["", "`"] {
            let blocks = parse(["Before **bold**.", "", fence("- Also this.", wrap), "", "After."].joined(separator: "\n"))
            #expect(blocks.count == 3, "wrap \(wrap)")
            guard case .alert(.insight, _) = blocks[1] else { Issue.record("no insight for wrap \(wrap): \(blocks)"); continue }
        }
        for literal in [["```text", "★ Insight " + rule, "literal", rule, "```"].joined(separator: "\n"),
                        ["- ```text", "  ★ Insight " + rule, "  literal", "  " + rule, "  ```"].joined(separator: "\n"),
                        ["    ★ Insight " + rule, "    literal", "    " + rule].joined(separator: "\n"),
                        ["Paragraph.", "    ★ Insight " + rule, "    literal", "    " + rule].joined(separator: "\n"),
                        fence("quoted").split(separator: "\n").map { "> " + $0 }.joined(separator: "\n"),
                        ["- item", "★ Insight " + rule, "lazy", rule].joined(separator: "\n")] {
            #expect(MarkdownDocument.rewritingInsights(literal) == literal, "\(literal)")
        }
        // A list closed by a blank line and an unindented line no longer protects the fence after it.
        let afterList = parse(["- item", "", "Text.", "", fence("Body.")].joined(separator: "\n"))
        guard case .alert(.insight, _)? = afterList.last else { Issue.record("no insight after a list: \(afterList)"); return }
    }

    /// A streaming insight that has not closed yet still draws as one; a closing line inside its code does not close it.
    @Test func openInsightAndFencedClosingLine() {
        let blocks = parse("★ Insight ─────\nText\n```\n─────\n```\nMore")
        #expect(blocks.count == 1)
        guard case .alert(.insight, let children) = blocks.first else { Issue.record("no insight: \(blocks)"); return }
        #expect(children.contains { if case .code = $0 { true } else { false } })
    }

    /// #34181: a quote in a sent message is a card between the text around it, two lines at most.
    @Test func quoteInASentMessageIsACard() {
        func cards(_ layout: MarkdownLayout) -> [CGRect] {
            layout.items.compactMap { if case .citationCard(let r, _) = $0 { r } else { nil } }
        }
        let short = ThreadAssistantCitation(environmentId: "e", threadId: "t", messageId: "m", text: "the quote", start: 0, end: 9,
                                            prefix: "", suffix: "", comment: "my note")
        let doc = MarkdownDocument(parsing: "Look at this \(short.markdown) and tell me.", preservesLineBreaks: true)
        let layout = ThreadDesign.layout(in: NSAppearance(named: .aqua)!, design: true) { MarkdownLayout(document: doc, width: 400) }
        let card = cards(layout)
        #expect(card.count == 1)
        // Text above, a one-line card 10.4pt below it, its comment, then the rest.
        #expect(card.first.map { $0.minY > 20 && $0.height == 32 } == true)
        #expect(layout.links.contains { $0.frame == card.first })
        let long = ThreadAssistantCitation(environmentId: "e", threadId: "t", messageId: "m", text: String(repeating: "word ", count: 200),
                                           start: 0, end: 1000, prefix: "a", suffix: "b", comment: nil)
        let clamped = ThreadDesign.layout(in: NSAppearance(named: .aqua)!, design: true) {
            MarkdownLayout(document: MarkdownDocument(parsing: long.markdown), width: 400)
        }
        #expect(cards(clamped).first?.height == 52)
    }

    /// #32402, #32403, #37750, #30762, #34006: which inline code becomes a file chip.
    @Test func inlineCodePathsAt4928() {
        for chip in ["docker/Dockerfile", "allocator.cc:217", "/Users/me/Mobile Documents/a - b.md", "src/a.ts:42-64",
                     "app/routes/posts.$id.tsx", "~/Library/Application Support/x.json"] {
            #expect(FileLinks.inlineCodeCandidate(chip) != nil, "\(chip)")
        }
        for code in ["/usr/bin/python3 -m venv .venv", "/usr/local/bin/node server.js", "/tmp/.../a.ts", "src/…/b.ts",
                     "I/W217:220", "example.com:8080", "foo bar/baz.ts", "docker/notes"] {
            #expect(FileLinks.inlineCodeCandidate(code) == nil, "\(code)")
        }
        #expect(FileLinks.parseLink("src/a.ts:42-64")?.line == 42)
        #expect(FileLinks.parseLink("src\\a.ts")?.path == "src/a.ts")
    }

    /// #42055 (5258 wordsHast.ts): with line breaks on, raw HTML paragraphs and list items keep their lines as HTML
    /// does, so no break lands inside them. CW shows raw HTML as text with HTML's whitespace collapsing.
    @Test func rawHTMLGetsNoLineBreaksWhenBreaksAreOn() {
        let blocks = parse("<p align=\"center\">\n  <img src=\"https://x.dev/a.png\" width=\"400\">\n</p>\n\n<ul>\n<li>\none\ntwo\n</li>\n</ul>")
        let texts = blocks.compactMap { block -> String? in
            if case .paragraph(let runs) = block { return runs.map(\.text).joined() }
            return nil
        }
        #expect(!texts.isEmpty)
        #expect(texts.allSatisfy { !$0.contains("\n") })
    }
}
