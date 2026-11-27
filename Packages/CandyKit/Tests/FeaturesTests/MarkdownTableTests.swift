import AppKit
import DesignSystem
import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct MarkdownTableTests {
    static let long = String(repeating: "A long cell with words and averylongunbrokenidentifier ", count: 4)
    static let source = "| Process | Status | Memory | Owner | Description | CPU |\n|---|---|---|---|---|---|\n| worker | running | 128 MB | sandbox | \(long) | 0.4% |"

    @Test(.threadDesign(true)) func defaultTablesWrapWithoutAnExpansionControl() throws {
        let view = view()
        let layout = view.layout(forWidth: 600)
        #expect(layout.controls.contains { if case .copyTable = $0.action { true } else { false } })
        let width = try #require(layout.items.compactMap { if case .scroll(_, _, let width) = $0 { width } else { nil } }.first)
        #expect(width == 600)
    }

    @Test(.threadDesign(true)) func defaultFormulaCellsKeepTheirNaturalWidth() {
        let formula = NSAttributedString(string: "\u{00A0}", attributes: [.markdownMath: true])
        let cells = [[NSAttributedString(string: "Column")], [formula]]
        let widths = MarkdownLayout.tableWidths(cells, columns: 1, width: 300,
                                              natural: { $0.attribute(.markdownMath, at: 0, effectiveRange: nil) != nil ? 700 : CGFloat($0.length * 10) })
        #expect(widths.tableWidth == 700)
    }

    private func view() -> MarkdownView {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        view.messageID = "table-test"
        view.setMarkdown("Before.\n\n" + Self.source + "\n\nAfter.")
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// T3 f8b06c5fd0 (index.css:2164-2178): a table shrinks to fit the lane, down to its longest words.
    @Test func tableFitsTheLane() throws {
        func cells(_ rows: [[String]]) -> [[NSAttributedString]] { rows.map { $0.map { NSAttributedString(string: $0) } } }
        let natural = { (s: NSAttributedString) in CGFloat(s.length * 10) }
        let rows = cells([["Name", "A very long header"], ["x", String(repeating: "word ", count: 20) + "unbreakable"]])
        // The lane splits the room over each column's longest word (52 and 122) by how much more each wants.
        let wide = MarkdownLayout.tableWidths(rows, columns: 2, width: 300, natural: natural)
        #expect(wide.tableWidth == 300 && abs(wide.widths[1] - (122 + 126 * 262 / 262)) < 0.01)
        // Below the longest words it overflows again.
        #expect(MarkdownLayout.tableWidths(rows, columns: 2, width: 100, natural: natural).tableWidth == 174)
        #expect(MarkdownLayout.tableCellPadding(0, of: 1) == (0, 0) && MarkdownLayout.tableCellPadding(1, of: 3) == (12, 24))
    }

    /// Inline code in a cell is one token: the column's minimum counts the chip's padding on both sides, so a narrow
    /// lane scrolls the table instead of breaking `kmh_to_mph` into `kmh_to_mp` and `h`.
    @Test(arguments: ["legacy", "modern", "redesign"]) func codeInACellNeverBreaksMidToken(design: String) throws {
        let modern: Bool? = design == "redesign" ? nil : design == "modern"
        try ThreadDesign.$layoutUses3814.withValue(modern) { try withTheme(SmallFixes3Pictures.redesign(dark: true)) {
            let source = "| Function | Result |\n|---|---|\n| `kmh_to_mph` | " + String(repeating: "converts kilometres per hour ", count: 6) + "|\n"
                + "| `mph_to_kmh_rounded_value` | the inverse |"
            let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 120, height: 200))
            view.messageID = "table-token-test"
            view.setMarkdown(source)
            for width in stride(from: CGFloat(60), through: 400, by: 7) {
                let codes = view.layout(forWidth: width).items.compactMap { item -> MarkdownTextBox? in
                    if case .text(let box, _) = item, box.text.contains("_") { return box }
                    return nil
                }
                try #require(codes.count == 2)
                for box in codes { #expect(box.lineCount == 1, "\(box.text) wraps at \(width)") }
            }
        } }
    }

    /// Redesign keeps a short cell whole in a narrow thread: `4 (0, 100, -40, 37)` never stacks one number a line, the
    /// table scrolls sideways instead, and Copy stays in the card's header row. A long prose cell still wraps at words.
    @Test func shortCellsStayWholeAndCopyStaysInTheHeader() throws {
        try ThreadDesign.$layoutUses3814.withValue(nil) { try withTheme(SmallFixes3Pictures.redesign(dark: true)) {
            let prose = String(repeating: "converts degrees and checks the round trip ", count: 3)
            let source = "| Test | Cases | Notes |\n|---|---|---|\n| test_c_to_f | 4 (0, 100, -40, 37) | \(prose) |\n| test_kmh | 3 (0, 10, 100) | ok |"
            let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
            view.messageID = "table-short-cells"
            view.setMarkdown(source)
            for width in stride(from: CGFloat(200), through: 520, by: 40) {
                let layout = view.layout(forWidth: width)
                let boxes = layout.items.compactMap { item -> MarkdownTextBox? in if case .text(let box, _) = item { box } else { nil } }
                for box in boxes where box.text.hasPrefix("4 (") || box.text.hasPrefix("3 (") || box.text.hasPrefix("test_") {
                    #expect(box.lineCount == 1, "\(box.text) wraps at \(width)")
                }
                let (viewport, content) = try #require(layout.items.compactMap { item -> (CGRect, CGFloat)? in
                    if case .scroll(let id, let viewport, let content) = item, id < 0 { return (viewport, content) }
                    return nil
                }.first)
                let copy = try #require(layout.controls.first { if case .copyTable = $0.action { true } else { false } })
                #expect(copy.frame.maxX <= width && copy.frame.minY >= viewport.minY, "Copy outside the card at \(width)")
                #expect(copy.frame.maxY < viewport.minY + 48, "Copy below the header row at \(width)")
                // A table that scrolls stops short of Copy's column (T4, round 2).
                if content > viewport.width { #expect(copy.frame.minX >= viewport.maxX, "Copy over scrolling cells at \(width)") }
            }
        } }
    }

    /// A table that scrolls keeps its columns' natural widths, so a prose cell out of view doesn't wrap and leave its
    /// row taller than the others (T4, Gemini, round 2).
    @Test func aScrollingTableKeepsItsRowsEven() throws {
        try ThreadDesign.$layoutUses3814.withValue(nil) { try withTheme(SmallFixes3Pictures.redesign(dark: true)) {
            let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
            view.messageID = "table-even-rows"
            view.setMarkdown("| Test | Cases | Result | Time | Notes |\n|---|---|---|---|---|\n"
                + "| test_c_to_f | 4 (0, 100, -40, 37) | ok | 0.001s | converts and checks the round trip |\n"
                + "| test_kmh_to_mph | 3 (0, 10, 100) | ok | 0.002s | rounds to two places |")
            let layout = view.layout(forWidth: 360)
            let boxes = layout.items.compactMap { item -> MarkdownTextBox? in if case .text(let box, _) = item { box } else { nil } }
            #expect(boxes.allSatisfy { $0.lineCount == 1 }, "\(boxes.filter { $0.lineCount > 1 }.map(\.text))")
        } }
    }

    /// Cells whose longest words together pass the lane still scroll sideways.
    static let wide = "| " + (0..<8).map { "column\($0)withaverylongunbrokenheadername" }.joined(separator: " | ") + " |\n|"
        + String(repeating: "---|", count: 8) + "\n| " + (0..<8).map { "cell\($0)withaverylongunbrokenvalueinside" }.joined(separator: " | ") + " |"

    @Test(.threadDesign(false)) func wideTableScrollsAndClamps() throws {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        view.messageID = "wide-table-test"
        view.setMarkdown("Before.\n\n" + Self.wide + "\n\nAfter.")
        view.layoutSubtreeIfNeeded()
        let scroller = try #require(view.layout(forWidth: 480).items.compactMap { item -> (Int, CGRect, CGFloat)? in
            if case .scroll(let id, let viewport, let width) = item { return (id, viewport, width) }
            return nil
        }.first)
        let (id, viewport, width) = scroller
        #expect(width > viewport.width)
        #expect(id < 0)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -80, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.location = CGPoint(x: viewport.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - (view.bounds.height - viewport.midY))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        #expect(view.codeOffsets[id] == 80)
        let shifted = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        shifted.flags = .maskShift
        shifted.location = cg.location
        view.scrollWheel(with: try #require(NSEvent(cgEvent: shifted)))
        #expect((view.codeOffsets[id] ?? 0) > 80)
        let offset = view.codeOffsets[id]
        view.setMarkdown("Before.\n\n" + Self.wide + "\n\nAfter. Streaming.")
        #expect(view.codeOffsets[id] == offset)
        let thumb = try #require(MarkdownView.codeThumb(viewport, width, 80))
        #expect(thumb.minX > viewport.minX && thumb.maxX < viewport.maxX)
    }

    /// An answer's unwrapped code survives its view being recycled for another answer, so the height the timeline
    /// cached with that choice still fits when the answer scrolls back.
    @Test(.threadDesign(false)) func recycledRowKeepsItsLayoutChoices() throws {
        let code = "```swift\nlet value = \"" + String(repeating: "a long line that wraps ", count: 12) + "\"\n```"
        func item(_ id: String, _ text: String) -> TimelineItem {
            let message = ChatMessage(id: MessageId(id), role: .assistant, text: text, createdAt: "2026-10-14T00:00:00Z")
            return TimelineItem(row: TimelineRow(id: id, createdAt: nil, kind: .message(
                message, projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false,
                assistantCopyStreaming: false)))
        }
        let filler = String(repeating: "Filler paragraph with enough words to take a few lines of the lane. ", count: 8)
        let items = [item("a", code)] + (0..<30).map { item("b\($0)", filler + "\n\n" + filler) }
        let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        timeline.layoutSubtreeIfNeeded()
        timeline.setItems(items)
        timeline.scroll(by: -timeline.documentHeight)
        let row = try #require(timeline.view(forRow: "a"))
        row.layoutSubtreeIfNeeded()
        let markdown = try #require(row.subviews.compactMap { $0 as? MarkdownView }.first)
        let before = row.frame.height
        markdown.toggleWrap(0)
        timeline.layoutSubtreeIfNeeded()
        #expect(row.frame.height != before)
        let changed = row.frame.height
        timeline.scroll(by: timeline.documentHeight)
        #expect(timeline.view(forRow: "a") == nil)
        timeline.scroll(by: -timeline.documentHeight)
        let back = try #require(timeline.view(forRow: "a"))
        back.layoutSubtreeIfNeeded()
        #expect(back.frame.height == changed)
        #expect(back.height(forWidth: back.frame.width) == back.frame.height)
        #expect(timeline.layoutProblems().isEmpty)
    }

    @Test func copyPreservesFullCellsAndEscapesCSV() throws {
        let document = MarkdownDocument(parsing: "| Name | Value |\n|---|---|\n| a,b | say \"hello\" |")
        guard case .table(let table) = document.blocks.first else { Issue.record("Expected table"); return }
        #expect(MarkdownLayout.tableCSV(table) == "Name,Value\n\"a,b\",\"say \"\"hello\"\"\"")
        #expect(MarkdownLayout.tableMarkdown(table).contains("a,b"))
    }
}
