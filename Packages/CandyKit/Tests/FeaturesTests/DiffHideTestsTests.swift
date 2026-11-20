import AppKit
import Testing
import DesignSystem
@testable import Features

/// #26730 and #29083: the test classifier, the file tree order, and the PR Code tab hiding tests.
@MainActor
struct DiffHideTestsTests {
    @Test func classifiesLikeT3() {
        // Cases from 4928 packages/shared/src/changedFileKind.test.ts.
        #expect(ChangedFileKind(path: "src/a.test.ts") == .tests)
        #expect(ChangedFileKind(path: "src/Button.stories.tsx") == .tests)
        #expect(ChangedFileKind(path: "Tests/FooTests.swift") == .tests)
        #expect(ChangedFileKind(path: "src/Latest.java") == .code)
        #expect(ChangedFileKind(path: "src/__snapshots__/a.snap") == .mocks)
        #expect(ChangedFileKind(path: "bun.lock") == .generated)
        #expect(ChangedFileKind(path: "README.md") == .docs)
        #expect(ChangedFileKind(path: "requirements.txt") == .code)
        #expect(ChangedFileKind.isTest("fixtures/a.json"))
        #expect(!ChangedFileKind.isTest("src/app.ts"))
    }

    @Test func treeOrderKeepsDirectoriesTogether() {
        let paths = ["src/b.ts", "README.md", "src/a/x.ts", "src/c.ts"]
        #expect(orderDiffPathsLikeTree(paths).map { paths[$0] } == ["src/b.ts", "src/a/x.ts", "src/c.ts", "README.md"])
    }

    @Test func codeTabHidesTests() {
        let saved = DiffHideTestFiles.value
        defer { DiffHideTestFiles.value = saved }
        DiffHideTestFiles.value = true
        let patch = ["app.ts", "app.test.ts"].map { "diff --git a/\($0) b/\($0)\n--- a/\($0)\n+++ b/\($0)\n@@ -1 +1 @@\n-a\n+b\n" }.joined()
        let view = PullRequestCodeView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.set(patches: [patch], loading: false, error: nil, nextCursor: nil, moreLoading: false, moreError: nil, commit: nil, commits: [])
        let list = view.subviews.compactMap { $0 as? ScrollAreaView }.compactMap { $0.scrollView.documentView as? DiffListView }.first
        #expect(list?.diff.files.map(\.path) == ["app.ts"])
        let link = view.subviews.compactMap { $0 as? LinkLabel }.first { !$0.isHidden && $0.text.contains("hidden") }
        #expect(link?.text == "1 test file hidden")
        link?.onClick?()
        #expect(list?.diff.files.count == 2)
        #expect(!DiffHideTestFiles.value)
    }
}
