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
}
