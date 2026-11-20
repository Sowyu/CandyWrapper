import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Nightly 4928 thread rows from the fourth pass (thread-4).
@MainActor
struct ThreadCatchUp4928Part4Tests {
    private func runs(_ text: String) -> [InlineRun] {
        guard case .paragraph(let runs)? = MarkdownDocument(parsing: text).blocks.first else { return [] }
        return runs
    }

    private func links(_ text: String) -> [String] {
        func walk(_ blocks: [MarkdownBlock]) -> [InlineRun] {
            blocks.flatMap { block -> [InlineRun] in
                switch block {
                case .paragraph(let runs), .heading(_, let runs): runs
                case .list(let list): list.items.flatMap { walk($0.blocks) }
                case .table(let table): (table.header + table.rows.flatMap { $0 }).flatMap { $0 }
                case .blockquote(let inner): walk(inner)
                default: []
                }
            }
        }
        return walk(MarkdownDocument(parsing: text).blocks).compactMap { run in run.link.map { "\(run.text)=>\($0.absoluteString)" } }
    }

    /// #35267 (shared/src/markdownPipeline.test.ts at 4928): bare URLs end at Chinese and Japanese punctuation.
    @Test func bareURLsEndAtCJKPunctuation() {
        let local = "http://localhost:18780=>http://localhost:18780"
        #expect(links("打开 http://localhost:18780，然后刷新") == [local])
        #expect(links("URL：https://example.com/a。下一句") == ["https://example.com/a=>https://example.com/a"])
        #expect(links("（预览：http://localhost:18780）") == [local])
        #expect(links("可以看了：**http://localhost:18780**（已重启）。") == [local])
        #expect(runs("可以看了：**http://localhost:18780**（已重启）。").last?.text == "（已重启）。")
        #expect(links("~~http://localhost:3001~~。") == ["http://localhost:3001=>http://localhost:3001"])
        #expect(links("www.example.com/preview。下一句") == ["www.example.com/preview=>http://www.example.com/preview"])
        #expect(links("https://example.com/a_。下一句") == ["https://example.com/a_=>https://example.com/a_"])
        #expect(links("https://example.com/a.，下一句") == ["https://example.com/a=>https://example.com/a"])
        #expect(links("https://example.com/search?q=hello，world") == ["https://example.com/search?q=hello=>https://example.com/search?q=hello"])
        #expect(links("http://a.com。http://b.com，").count == 2)
        #expect(links("# **http://localhost:3000**，刷新") == ["http://localhost:3000=>http://localhost:3000"])
        // Unicode earlier in the URL keeps the mark; code, labels and destinations stay as typed.
        #expect(links("https://example.com/日本語，続き").first?.hasPrefix("https://example.com/日本語，続き") == true)
        #expect(links("`https://example.com/a。次`").isEmpty)
        #expect(links("[記事](https://example.com/a，b)").count == 1)
        #expect(links("```\nhttp://a.com，b\n```").isEmpty)
        #expect(MarkdownDocument.endingBareURLsAtCJKPunctuation("plain https://a.com, text") == "plain https://a.com, text")
    }

    /// #34306 (useTallEnoughToFold.ts at 4928): "Show full message" appears only when the text is at least twice the
    /// 176pt fold, however many lines or characters it has.
    @Test func userMessagesFoldOnlyWhenOpeningDoublesThem() throws {
        func toggleShown(_ text: String, width: CGFloat = 736) throws -> Bool {
            let row = UserMessageRowView()
            row.context = TimelineContext()
            row.configure(PromptAndPreviewLayoutTests.item(images: 0, text: text))
            row.frame = CGRect(x: 0, y: 0, width: width, height: row.height(forWidth: width))
            row.layoutSubtreeIfNeeded()
            let bubble = try #require(row.subviews.first { $0.subviews.contains { $0 is MarkdownView } })
            return try #require(bubble.subviews.compactMap { $0 as? ButtonView }.first).isHidden == false
        }
        // Ten short lines used to fold by T3's old line count; they are under 352pt, so they no longer do.
        #expect(try !toggleShown((1...10).map { "Line \($0)" }.joined(separator: "\n")))
        #expect(try !toggleShown(String(repeating: "word ", count: 130)))
        #expect(try toggleShown((1...30).map { "Line \($0)" }.joined(separator: "\n")))
        // The same text folds in a narrow lane, where it wraps past the threshold.
        let long = String(repeating: "word ", count: 400)
        #expect(try toggleShown(long, width: 320))
        #expect(UserMessageRowView.tallEnoughToFold(352) && !UserMessageRowView.tallEnoughToFold(351.5))
    }
}
