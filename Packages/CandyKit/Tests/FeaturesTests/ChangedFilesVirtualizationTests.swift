import AppKit
import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct ChangedFilesVirtualizationTests {
    @Test func largeTreeReusesOnlyViewportRows() throws {
        let files = (0..<2_000).map { CheckpointFile(path: String(format: "src/file%04d.swift", $0), additions: 1, deletions: 0) }
        let summary = TurnDiffSummary(checkpointId: "c", scopeId: "s", runId: "r", checkpointTurnCount: 1, checkpointRef: "ref", status: "ready",
                                      files: files, assistantMessageId: nil, completedAt: T3Timestamp(stringLiteral: "2026-10-10T00:00:00Z"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        let card = ChangedFilesCardView(frame: NSRect(x: 0, y: 0, width: 420,
            height: ChangedFilesCardView.height(files, allExpanded: true, overrides: [:])))
        scroll.documentView = card
        let model = ThreadViewModel()
        var opened: String?
        model.onOpenTurnDiff = { _, path in opened = path }
        card.model = model
        card.configure(summary, allExpanded: true, overrides: [:])
        card.layoutSubtreeIfNeeded()
        #expect(card.rows.count == 2_001)
        #expect(card.createdRowViews < 24)
        func visibleRows() -> [ChangedFileRowView] {
            card.subviews.compactMap { $0 as? ChangedFileRowView }.filter { !$0.isHidden }
        }
        let folder = try #require(visibleRows().first { $0.accessibilityLabel() == "src" })
        #expect(folder.frame.minY == 48 && folder.frame.height == 28.5)
        let file = try #require(visibleRows().first { $0.accessibilityLabel() == "src/file0000.swift" })
        #expect(file.frame.minY == 76.5 && file.frame.height == 28)
        for y in stride(from: CGFloat(0), through: card.frame.height - 400, by: 399) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            card.updateVisibleRows()
            let visible = visibleRows()
            #expect(visible.count < 26)
            #expect(visible.contains { $0.frame.contains(NSPoint(x: 20, y: y + 200)) })
        }
        let recycledFile = try #require(visibleRows().first)
        #expect(recycledFile.accessibilityPerformPress())
        #expect(opened == recycledFile.accessibilityLabel())
        // Scrolling the whole 2,001-row tree allocates at most one viewport plus overscan.
        #expect(card.createdRowViews < 26)
        #expect(card.subviews.compactMap { $0 as? ChangedFileRowView }.count < 26)
        scroll.contentView.scroll(to: .zero)
        card.configure(summary, allExpanded: false, overrides: [:])
        card.setFrameSize(NSSize(width: 420, height: ChangedFilesCardView.height(files, allExpanded: false, overrides: [:])))
        card.layoutSubtreeIfNeeded()
        #expect(visibleRows().count == 1)
        #expect(visibleRows().first?.accessibilityLabel() == "src")
    }
}
