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

    private func view() -> MarkdownView {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        view.messageID = "table-test"
        view.setMarkdown("Before.\n\n" + Self.source + "\n\nAfter.")
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func expansionReusesOtherBlocksAndSurvivesStreaming() throws {
        let view = view()
        let collapsed = view.layout(forWidth: 480)
        let button = try #require(view.subviews.compactMap { $0 as? ButtonView }.first { $0.accessibilityLabel() == "Expand table cells" })
        #expect(button.icon == .maximize2 && button.variant == .ghostMuted)
        button.action?()
        let expanded = view.layout(forWidth: 480)
        #expect(expanded.height > collapsed.height)
        #expect(expanded.reusedBlocks == 2)
        view.layoutSubtreeIfNeeded()
        #expect(button.accessibilityLabel() == "Collapse table cells")
        #expect(button.icon == .minimize2 && button.variant == .secondary)
        view.setMarkdown("Before.\n\n" + Self.source + "\n\nAfter. More text.")
        #expect(view.expandedTables == [0])
        view.toggleTable(0)
        #expect(view.expandedTables.isEmpty)
        view.toggleTable(0)
        view.messageID = "different-message"
        #expect(view.expandedTables.isEmpty)
    }

    @Test func eachTableKeepsItsStateAsRowsStream() {
        let view = view()
        view.setMarkdown(Self.source + "\n\n" + Self.source)
        view.toggleTable(1)
        let before = view.layout(forWidth: 480)
        view.setMarkdown(Self.source + "\n\n" + Self.source + "\n| second | idle | 1 MB | sandbox | " + Self.long + " | 0% |")
        let after = view.layout(forWidth: 480)
        #expect(view.expandedTables == [1])
        #expect(after.reusedBlocks == 1)
        #expect(after.height > before.height)
        let controls = after.controls.filter { if case .toggleTable = $0.action { return true }; return false }
        #expect(controls.map(\.icon) == [.maximize2, .minimize2])
    }

    private func toggles(_ markdown: String, expand: Bool = false) -> [IconName?] {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        view.setMarkdown(markdown)
        if expand { view.toggleTable(0) }
        return view.layout(forWidth: 480).controls.compactMap { control in
            if case .toggleTable = control.action { return control.icon }
            return nil
        }
    }

    @Test func toggleShowsOnlyWhenACellIsClipped() throws {
        #expect(toggles("| Name | Value |\n|---|---|\n| a | b |").isEmpty)
        #expect(toggles(Self.source) == [.maximize2])
        #expect(toggles("| \(Self.long) | Value |\n|---|---|\n| a | b |") == [.maximize2])
        #expect(toggles(Self.source, expand: true) == [.minimize2])
        // The copy menu stays right-aligned without the toggle.
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        view.setMarkdown("| Name | Value |\n|---|---|\n| a | b |")
        let copy = try #require(view.layout(forWidth: 480).controls.first { if case .copyTable = $0.action { return true }; return false })
        #expect(copy.frame.maxX == 480)
    }

    /// T3 f8b06c5fd0 (index.css:2164-2178): from a 36rem lane an expanded table shrinks to fit, down to its longest words.
    @Test func expandedTableFitsAWideLane() throws {
        func cells(_ rows: [[String]]) -> [[NSAttributedString]] { rows.map { $0.map { NSAttributedString(string: $0) } } }
        let natural = { (s: NSAttributedString) in CGFloat(s.length * 10) }
        let rows = cells([["Name", "A very long header"], ["x", String(repeating: "word ", count: 20) + "unbreakable"]])
        // Narrow lanes keep max-content: the body column stops at 384, the header column doesn't.
        let narrow = MarkdownLayout.expandedTableWidths(rows, columns: 2, width: 300, fitsLane: false, natural: natural)
        // Each of the two columns pads only its inner side since 3669 (index.css:2146-2152).
        #expect(narrow.widths == [52, 384] && narrow.tableWidth == 436)
        // A wide lane splits the room over each column's longest word (52 and 122) by how much more each wants.
        let wide = MarkdownLayout.expandedTableWidths(rows, columns: 2, width: 300, fitsLane: true, natural: natural)
        #expect(wide.tableWidth == 300 && abs(wide.widths[1] - (122 + 126 * 262 / 262)) < 0.01)
        // Below the longest words it overflows again.
        #expect(MarkdownLayout.expandedTableWidths(rows, columns: 2, width: 100, fitsLane: true, natural: natural).tableWidth == 174)
        #expect(MarkdownLayout.tableCellPadding(0, of: 1) == (0, 0) && MarkdownLayout.tableCellPadding(1, of: 3) == (12, 24))
        // A view outside the timeline never fits; one in a wide lane scrolls less.
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.setMarkdown(Self.source)
        view.toggleTable(0)
        func contentWidth(_ layout: MarkdownLayout) -> CGFloat? {
            layout.items.compactMap { if case .scroll(_, _, let w) = $0 { return w }; return nil }.first
        }
        let scrolling = try #require(contentWidth(view.layout(forWidth: 600)))
        view.chatLaneInset = 8
        let fitted = try #require(contentWidth(view.layout(forWidth: 600)))
        #expect(scrolling > 600 && fitted == 600)
    }

    @Test func wideTableScrollsAndClamps() throws {
        let view = view()
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
        view.setMarkdown("Before.\n\n" + Self.source + "\n\nAfter. Streaming.")
        #expect(view.codeOffsets[id] == offset)
        let thumb = try #require(MarkdownView.codeThumb(viewport, width, 80))
        #expect(thumb.minX > viewport.minX && thumb.maxX < viewport.maxX)
    }

    @Test func expandingUpdatesTheTimelineRowHeight() throws {
        let (_, original) = try TimelineTilingTests.liveParts(ThreadTimelineTests.manyItems(copies: 1))
        var message = original
        message.text = Self.source
        message.streaming = false
        let item = TimelineItem(row: TimelineRow(id: "table-row", createdAt: nil, kind: .message(
            message, projectedItem: nil, showAssistantMeta: true, showAssistantCopyButton: true,
            assistantCopyStreaming: false, turnDiffSummary: nil)))
        let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        timeline.layoutSubtreeIfNeeded()
        timeline.setItems([item])
        let row = try #require(timeline.view(forRow: "table-row"))
        row.layoutSubtreeIfNeeded()
        let markdown = try #require(row.subviews.compactMap { $0 as? MarkdownView }.first)
        let before = row.frame.height
        markdown.toggleTable(0)
        timeline.layoutSubtreeIfNeeded()
        #expect(row.frame.height > before)
        #expect(timeline.layoutProblems().isEmpty)
        markdown.toggleTable(0)
        timeline.layoutSubtreeIfNeeded()
        #expect(row.frame.height == before)
    }

    /// An answer's expanded table or unwrapped code survives its view being recycled for another answer, so the height
    /// the timeline cached with that choice still fits when the answer scrolls back.
    @Test(arguments: [true, false]) func recycledRowKeepsItsLayoutChoices(table: Bool) throws {
        let code = "```swift\nlet value = \"" + String(repeating: "a long line that wraps ", count: 12) + "\"\n```"
        func item(_ id: String, _ text: String) -> TimelineItem {
            let message = ChatMessage(id: MessageId(id), role: .assistant, text: text, createdAt: "2026-10-14T00:00:00Z")
            return TimelineItem(row: TimelineRow(id: id, createdAt: nil, kind: .message(
                message, projectedItem: nil, showAssistantMeta: false, showAssistantCopyButton: false,
                assistantCopyStreaming: false, turnDiffSummary: nil)))
        }
        let filler = String(repeating: "Filler paragraph with enough words to take a few lines of the lane. ", count: 8)
        let items = [item("a", table ? Self.source : code)] + (0..<30).map { item("b\($0)", filler + "\n\n" + filler) }
        let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        timeline.layoutSubtreeIfNeeded()
        timeline.setItems(items)
        timeline.scroll(by: -timeline.documentHeight)
        let row = try #require(timeline.view(forRow: "a"))
        row.layoutSubtreeIfNeeded()
        let markdown = try #require(row.subviews.compactMap { $0 as? MarkdownView }.first)
        let before = row.frame.height
        if table { markdown.toggleTable(0) } else { markdown.toggleWrap(0) }
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
