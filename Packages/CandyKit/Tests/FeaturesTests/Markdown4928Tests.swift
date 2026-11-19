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
}
