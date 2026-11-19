import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// A 4928 server sends the first 200 changed files and `filesTotal` for all of them
/// (ChangedFilesTree.tsx:57-80, 148-162).
@MainActor
struct ChangedFilesTotalsTests {
    @Test func truncatedCheckpointCountsEveryFileAndOffersTheFullDiff() throws {
        let files = (0..<200).map { CheckpointFile(path: "f\($0).swift", additions: 2, deletions: 1) }
        let summary = TurnDiffSummary(checkpointId: "c", scopeId: "s", runId: "r", checkpointTurnCount: 1, checkpointRef: "ref", status: "ready",
                                      files: files, filesTotal: CheckpointFileTotals(count: 201, additions: 410, deletions: 205),
                                      assistantMessageId: nil, completedAt: T3Timestamp(stringLiteral: "2026-11-19T00:00:00Z"))
        #expect(summary.hiddenFileCount == 1)
        let plain = ChangedFilesCardView.height(files, allExpanded: true, overrides: [:])
        let height = ChangedFilesCardView.height(files, allExpanded: true, overrides: [:], hiddenFiles: 1)
        #expect(height == plain + ChangedFilesCardView.moreFilesHeight)

        let card = ChangedFilesCardView(frame: NSRect(x: 0, y: 0, width: 420, height: height))
        let model = ThreadViewModel()
        var opened: (String, String?)?
        model.onOpenTurnDiff = { run, path in opened = (run.rawValue, path) }
        card.model = model
        card.configure(summary, allExpanded: true, overrides: [:])
        card.layoutSubtreeIfNeeded()
        let labels = Self.texts(in: card)
        #expect(labels.contains("201 changed files"))
        let more = try #require(card.subviews.compactMap { $0 as? ButtonView }.first { $0.title == "1 more file in the full diff" })
        #expect(!more.isHidden)
        #expect(more.frame.maxY <= height)
        #expect(more.accessibilityPerformPress())
        #expect(opened?.0 == "r" && opened?.1 == "f0.swift")

        // A complete list shows no button.
        var full = summary
        full.filesTotal = nil
        card.configure(full, allExpanded: true, overrides: [:])
        #expect(Self.texts(in: card).contains("200 changed files"))
        #expect(card.subviews.compactMap { $0 as? ButtonView }.allSatisfy { $0.isHidden || !($0.title ?? "").contains("more file") })
    }

    static func texts(in view: NSView) -> [String] {
        view.subviews.compactMap { ($0 as? LabelView)?.text } + view.subviews.flatMap { texts(in: $0) }
    }
}
