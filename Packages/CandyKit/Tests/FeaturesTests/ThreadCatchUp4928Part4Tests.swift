import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
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

    /// #22349 (HtmlRenderDialog.tsx at 4928): the full-screen card is at most 1176pt wide, as tall as the page up to
    /// its cap, and the frame keeps the card's width at every zoom, so the page reflows instead of scaling.
    @Test func htmlDialogFitsItsPage() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        let ref = HtmlRenderReference(attachmentId: "a", title: "Chart", height: 300)
        let dialog = HtmlRenderDialogView(page: .init(src: URL(string: "about:blank")!, title: "Chart", dark: false), reference: ref) { _, _ in }
        dialog.present(in: window)
        dialog.layoutSubtreeIfNeeded()
        let frame = try #require(dialog.firstDescendant(of: ThreadWebFrameView.self))
        #expect(frame.frame == NSRect(x: 16, y: 16, width: 1144, height: 300))
        let card = try #require(frame.superview?.enclosingScrollView?.superview)
        #expect(card.frame.width == 1178 && card.frame.height == 334)
        dialog.dismiss()
    }

    /// #34006 (markdownLinks.ts at 4928): a label naming a line range matches only the same range.
    @Test func fileLinkLabelsCompareTheEndLine() {
        #expect(FileLinks.isFileLinkLabel("src/a.ts:42-64", href: "src/a.ts:42-64"))
        #expect(!FileLinks.isFileLinkLabel("src/a.ts:42-64", href: "src/a.ts:42-70"))
        #expect(!FileLinks.isFileLinkLabel("src/a.ts:42-64", href: "src/a.ts:42"))
        #expect(FileLinks.isFileLinkLabel("src/a.ts:42", href: "src/a.ts:42-64"))
        #expect(FileLinks.endLine("a.ts#L3-L9") == 9 && FileLinks.endLine("a.ts:9-3") == nil)
    }

    /// #34181 (AssistantCitationChip.tsx at 4928): a quote card and its comment are one copy boundary, so every box
    /// of the card copies the same quote, comment included, and a selection across them copies it once.
    @Test func quoteCardsCopyAsOneLink() throws {
        let quote = ThreadAssistantCitation(environmentId: "e", threadId: "t", messageId: "m", text: "Hello there", start: 0, end: 11,
                                            prefix: "", suffix: "", comment: nil).withComment("Why?")
        let doc = MarkdownDocument(parsing: quote.markdown, preservesLineBreaks: true)
        let layout = ThreadDesign.layout(in: NSAppearance(named: .aqua)!, design: true) { MarkdownLayout(document: doc, width: 400) }
        let boxes = layout.items.compactMap { if case .text(let box, _) = $0 { box } else { nil } }
        let pieces = boxes.flatMap { $0.copyPieces(NSRange(location: 0, length: ($0.text as NSString).length)) }
        try #require(pieces.count >= 2)
        #expect(pieces.allSatisfy { $0.card && $0.text == quote.markdown })
    }

    /// #36779: Arabic commas and question marks end a bare URL too.
    @Test func bareURLsEndAtArabicPunctuation() {
        #expect(links("افتح https://example.com/a، ثم") == ["https://example.com/a=>https://example.com/a"])
        #expect(links("هل https://example.com/a؟ نعم") == ["https://example.com/a=>https://example.com/a"])
    }

    /// #35859 (CHAT_USER_MARKDOWN_REMARK_PLUGINS at 4928): sent messages keep single tildes; `~~double~~` still strikes.
    @Test func sentMessagesKeepSingleTildes() {
        func struck(_ text: String, user: Bool) -> [String] {
            guard case .paragraph(let runs)? = MarkdownDocument(parsing: text, preservesLineBreaks: user).blocks.first else { return [] }
            return runs.filter(\.strikethrough).map(\.text)
        }
        #expect(struck("see ~/a and (~/b) here", user: true).isEmpty)
        #expect(struck("a ~~gone~~ b", user: true) == ["gone"])
        #expect(struck("see ~/a and (~/b) here", user: false) == ["/a and ("])
        guard case .paragraph(let runs)? = MarkdownDocument(parsing: "run `~x~` and ~/a", preservesLineBreaks: true).blocks.first else { Issue.record("no paragraph"); return }
        #expect(runs.map(\.text).joined() == "run ~x~ and ~/a")
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let hit = sub as? T { return hit }
            if let hit = sub.firstDescendant(of: type) { return hit }
        }
        return nil
    }
}
