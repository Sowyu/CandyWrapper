import AppKit
import Testing
import T3Protocol
@testable import Features

@MainActor
struct DiffContextTests {
    nonisolated static let patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -119,3 +119,3 @@\n line 119\n-line 120\n+changed\n line 121\n"
    nonisolated static let contents = ReviewDiffFileContents(
        oldContents: (1...240).map { "line \($0)\n" }.joined(),
        newContents: (1...240).map { $0 == 120 ? "changed\n" : "line \($0)\n" }.joined())

    static func layout(_ diff: UnifiedDiff, expands: Bool) -> DiffLayout {
        DiffLayout(diff: diff, collapsed: [], style: .unified, width: 480, wrap: true, ch: 7.8, expandsContext: expands)
    }

    @Test func unknownTailRequiresALoaderAndAModifiedFile() {
        let diff = UnifiedDiff(Self.patch)
        #expect(Self.layout(diff, expands: false).rows.filter { $0.kind == .separator }.map(\.right) == [118])
        #expect(Self.layout(diff, expands: true).rows.filter { $0.kind == .separator }.map(\.right) == [118, -1])
        let added = UnifiedDiff("diff --git a/new b/new\nnew file mode 100644\n--- /dev/null\n+++ b/new\n@@ -0,0 +1 @@\n+new\n")
        #expect(!Self.layout(added, expands: true).rows.contains { $0.kind == .separator })
    }

    @Test func revealsBothEndsInChunksAndRemovesTheKnownEmptyTail() throws {
        var diff = UnifiedDiff(Self.patch)
        diff = try diff.expandingContext(file: 0, gap: 0, contents: Self.contents, direction: .down)
        #expect(diff.files[0].hunks[0].oldStart == 19)
        #expect(Self.layout(diff, expands: true).rows.filter { $0.kind == .separator }.map(\.right) == [18, 119])
        diff = try diff.expandingContext(file: 0, gap: 0, contents: Self.contents, direction: .down)
        diff = try diff.expandingContext(file: 0, gap: 1, contents: Self.contents, direction: .up)
        #expect(Self.layout(diff, expands: true).rows.filter { $0.kind == .separator }.map(\.right) == [19])
        diff = try diff.expandingContext(file: 0, gap: 1, contents: Self.contents, direction: .up)
        #expect(!Self.layout(diff, expands: true).rows.contains { $0.kind == .separator })
        #expect(diff.lines.count == 241)
        #expect(diff.additions == 1 && diff.deletions == 1)
        #expect(diff.text(diff.lines.last!) == "line 240")
        #expect(diff.lines.last?.newNumber == 240)
    }

    @Test func expandsMiddleGapsAndMergesTouchingHunks() throws {
        let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -3 +3 @@\n-3\n+three\n@@ -8 +8 @@\n-8\n+eight\n"
        let contents = ReviewDiffFileContents(oldContents: (1...10).map { "\($0)\n" }.joined(),
            newContents: (1...10).map { $0 == 3 ? "three\n" : $0 == 8 ? "eight\n" : "\($0)\n" }.joined())
        let diff = try UnifiedDiff(patch).expandingContext(file: 0, gap: 1, contents: contents, direction: .both, count: 2)
        #expect(diff.files[0].hunks.count == 1)
        #expect(diff.files[0].hunks[0].oldStart == 3 && diff.files[0].hunks[0].oldCount == 6)
        #expect(diff.lines.filter { $0.kind == .context }.map { diff.text($0) } == ["4", "5", "6", "7"])
    }

    @Test func refusesStaleContentsAndHandlesAnInsertionAtTheStart() throws {
        var stale = Self.contents
        stale.oldContents = stale.oldContents.replacingOccurrences(of: "line 120\n", with: "newer checkout\n")
        #expect(throws: UnifiedDiff.ContextError.self) {
            try UnifiedDiff(Self.patch).expandingContext(file: 0, gap: 1, contents: stale, direction: .up)
        }
        let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+new\n"
        let diff = try UnifiedDiff(patch).expandingContext(file: 0, gap: 1,
            contents: .init(oldContents: "tail\n", newContents: "new\ntail\n"), direction: .up)
        #expect(diff.files[0].hunks[0].oldStart == 1 && diff.files[0].hunks[0].oldCount == 1)
        #expect(diff.lines.last?.oldNumber == 1 && diff.lines.last?.newNumber == 2)
    }

    @Test func requestsOnlyOnExpansionAndReusesTheHydratedContents() async {
        actor Calls { var count = 0; func add() { count += 1 } }
        let calls = Calls(), list = DiffListView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
        list.loadDiffFiles = { _ in await calls.add(); return Self.contents }
        list.setDiff(UnifiedDiff(Self.patch), collapsedByDefault: false)
        #expect(await calls.count == 0)
        list.expandContext(file: 0, gap: 1, direction: .up)
        #expect(await eventually { list.diff.files[0].newLineCount == 240 })
        list.expandContext(file: 0, gap: 1, direction: .up)
        #expect(await eventually { list.diff.lines.last?.newNumber == 240 })
        #expect(await calls.count == 1)
    }

    @Test func oldLoadsCannotReplaceANewSelection() async {
        let list = DiffListView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
        list.loadDiffFiles = { _ in
            try? await Task.sleep(for: .milliseconds(30))
            return Self.contents
        }
        list.setDiff(UnifiedDiff(Self.patch), collapsedByDefault: false)
        list.expandContext(file: 0, gap: 1, direction: .up)
        list.setDiff(UnifiedDiff(""))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(list.diff.files.isEmpty && list.diff.lines.isEmpty)
    }
}
