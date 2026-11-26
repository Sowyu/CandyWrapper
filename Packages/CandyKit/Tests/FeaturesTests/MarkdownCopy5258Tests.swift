import AppKit
import Testing
@testable import Features

/// T3 5258 Markdown copies: a table as HTML (markdown-clipboard.ts:494-677, #33286) and list markers in a
/// selection across items (markdown-clipboard.ts:129-152, #39150).
@MainActor
struct MarkdownCopy5258Tests {
    @Test func tableCopiesAsInlineStyledHTML() throws {
        let document = MarkdownDocument(parsing: "| Name | Cost |\n|---|---:|\n| a < b & \"c\" | $5 |")
        guard case .table(let table) = document.blocks.first else { Issue.record("Expected table"); return }
        let cell = "border:1px solid #d0d7de;padding:6px 12px;vertical-align:top"
        let head = cell + ";background-color:#f6f8fa;color:#1f2328;font-weight:600"
        // Foundation reports an unaligned column as left, so its body cells say so too; a paste looks the same.
        #expect(MarkdownLayout.tableHTML(table) == """
        <table dir="ltr" style="border-collapse:collapse">
          <thead>
            <tr><th style="\(head);text-align:left">Name</th><th style="\(head);text-align:right">Cost</th></tr>
          </thead>
          <tbody>
            <tr><td style="\(cell);text-align:left">a &lt; b &amp; &quot;c&quot;</td><td style="\(cell);text-align:right">$5</td></tr>
          </tbody>
        </table>
        """)
    }

    @Test func aSelectionAcrossListItemsKeepsTheirMarkers() {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.setMarkdown("3. first\n4. second\n   - [x] done\n")
        let text = view.selectionText as NSString
        #expect(view.copiedText(NSRange(location: 0, length: text.length)) == "3. first\n4. second\n   - [x] done")
        // Inside one item, the text copies bare.
        #expect(view.copiedText(text.range(of: "second")) == "second")
    }
}

/// File chips show a line range, and find in thread matches it (threadFindText.ts, fileLinks.ts:182-199, #39308).
@MainActor
struct FileLinkRange5258Tests {
    @Test func rangesShowInTheLabel() throws {
        let link = try #require(FileLinks.resolveLink("src/notes.ts#L42-L64", cwd: "/workspace/repo"))
        #expect(FileLinks.label(link, suffixes: [:]) == "notes.ts · L42–64")
        let code = try #require(FileLinks.resolveInlineCode("test/notes.ts:42-64", cwd: "/workspace/repo"))
        #expect(FileLinks.label(code, suffixes: [:]) == "notes.ts · L42–64")
        let reversed = try #require(FileLinks.resolveLink("/tmp/notes.ts#L64-L42", cwd: nil))
        #expect(FileLinks.label(reversed, suffixes: [:]) == "notes.ts · L64")
        let column = try #require(FileLinks.resolveLink("/tmp/a.ts:12:3", cwd: nil))
        #expect(FileLinks.label(column, suffixes: [:]) == "a.ts · L12:C3")
        // A decomposed name composes for display.
        let nfd = try #require(FileLinks.resolveLink("/tmp/cafe\u{301}.ts", cwd: nil))
        #expect(FileLinks.label(nfd, suffixes: [:]) == "caf\u{E9}.ts")
    }
}

/// Find scrolls a wide table to the selected match, as it does a code block (useThreadFindNavigation.ts:7-8, #39295).
@MainActor
struct FindWideTable5258Tests {
    @Test func aMatchInAClippedTableCellScrollsIntoView() {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        let wide = (1...8).map { "Column\($0)Heading" }
        view.setMarkdown("| " + wide.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 8) + "\n| " + (1...7).map { "c\($0)" }.joined(separator: " | ") + " | needle |\n")
        view.layoutSubtreeIfNeeded()
        view.threadFindQuery = "needle"
        view.threadFindOccurrence = 0
        let rect = view.activeFindRect()
        #expect(rect != nil)
        if let rect { #expect(rect.minX >= 0 && rect.maxX <= view.bounds.width) }
    }
}
