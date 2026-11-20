import AppKit
import Testing
import DesignSystem
@testable import Features

/// #37007: a file the host withheld shows "Diff too large to display." with Load diff, and its own read replaces it.
@MainActor
struct PullRequestWithheldFileTests {
    static let big = "diff --git a/big.json b/big.json\nindex 1..2 100644\n--- a/big.json\n+++ b/big.json\n"
    static let small = "diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1 +1 @@\n-a\n+b\n"
    static let bigRead = "diff --git a/big.json b/big.json\n--- a/big.json\n+++ b/big.json\n@@ -1 +1,2 @@\n x\n+y\n"

    @Test func splicesReadFiles() {
        let spliced = PullRequestDetailLogic.splicingWithheld(Self.small + Self.big, loaded: ["big.json": Self.bigRead])
        let diff = UnifiedDiff(spliced)
        #expect(diff.files.map(\.path) == ["a.ts", "big.json"])
        #expect(diff.files[1].hunks.count == 1)
        #expect(PullRequestDetailLogic.splicingWithheld(Self.small, loaded: [:]) == Self.small)
    }

    @Test func noticeLoadsTheFile() throws {
        let view = PullRequestCodeView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var asked: [String] = []
        view.onLoadWithheld = { asked.append($0) }
        view.set(patches: [Self.small + Self.big], loading: false, error: nil, nextCursor: nil, moreLoading: false, moreError: nil, commit: nil, commits: [])
        view.setWithheld(omitted: ["big.json": (40_000, 2)], readable: true, loaded: [:], status: [:])
        let list = try #require(view.subviews.compactMap { $0 as? ScrollAreaView }.compactMap { $0.scrollView.documentView as? DiffListView }.first)
        list.setCollapsedFiles([])
        view.layoutSubtreeIfNeeded()
        list.layoutSubtreeIfNeeded()
        #expect(list.diff.files[1].additions == 40_000)
        #expect(list.placedAnnotationIds.contains("withheld:big.json"))
        let notice = try #require(list.subviews.compactMap { $0 as? PullRequestWithheldFileNotice }.first)
        #expect(notice.accessibilityLabel() == "Diff too large to display.")
        let button = try #require(notice.subviews.compactMap { $0 as? ButtonView }.first)
        button.action?()
        #expect(asked == ["big.json"])
        view.setWithheld(omitted: ["big.json": (40_000, 2)], readable: true, loaded: ["big.json": Self.bigRead], status: [:])
        #expect(list.diff.files[1].hunks.count == 1)
        #expect(!list.placedAnnotationIds.contains("withheld:big.json"))
    }
}
