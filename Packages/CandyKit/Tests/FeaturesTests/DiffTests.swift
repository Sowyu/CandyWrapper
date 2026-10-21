import AppKit
import Foundation
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Unified diff parsing (the `diff` text of `orchestration.getTurnDiff`), row layout and the
/// virtualized list's cost for a 20,000-line diff.
@MainActor
struct DiffTests {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The `diff` of the recorded getFullThreadDiff reply in fixtures/transcripts/03-turn2.jsonl.
    static func recordedPatch() throws -> String {
        let text = try String(contentsOf: repo.appending(path: "fixtures/transcripts/03-turn2.jsonl"), encoding: .utf8)
        for line in text.split(separator: "\n") where line.contains("diff --git") {
            let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let exit = (json["body"] as! [String: Any])["exit"] as! [String: Any]
            return (exit["value"] as! [String: Any])["diff"] as! String
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    @Test func recordedTurnDiff() throws {
        let diff = UnifiedDiff(try Self.recordedPatch())
        #expect(diff.files.map(\.path) == ["hello.py", "notes.md"])
        let hello = diff.files[0], notes = diff.files[1]
        #expect(hello.change == .change)
        #expect((hello.additions, hello.deletions) == (1, 0))
        #expect(hello.hunks.count == 1)
        #expect(hello.hunks[0].collapsedBefore == 0)
        let lines = hello.hunks[0].lines.map { diff.lines[$0] }
        #expect(lines.map(\.kind) == [.context, .addition, .context])
        #expect(lines.map(\.newNumber) == [1, 2, 3])
        #expect(lines.map(\.oldNumber) == [1, 0, 2])
        #expect(diff.text(lines[1]) == "    \"\"\"Return a greeting string for the given name.\"\"\"")
        #expect(notes.change == .new && notes.oldPath == nil)
        #expect((notes.additions, notes.deletions) == (3, 0))
        #expect(diff.text(diff.lines[notes.hunks[0].lines.last!]) == "- [ ] Run the test suite before every commit")
        #expect(notes.language == "md" && hello.language == "py")
        #expect((diff.additions, diff.deletions) == (4, 0))
    }

    @Test func hunksSeparatorsAndNoNewline() {
        let patch = """
        diff --git a/a.ts b/a.ts
        index 1..2 100644
        --- a/a.ts
        +++ b/a.ts
        @@ -3,3 +3,4 @@ fn ctx
         keep
        -old
        +new one
        +new two
         tail
        @@ -20,2 +21,2 @@
        --- a deleted line that looks like a header
        +++ an added line that looks like a header
         end
        \\ No newline at end of file

        """
        let diff = UnifiedDiff(patch)
        #expect(diff.files.count == 1)
        let file = diff.files[0]
        #expect(file.hunks.count == 2)
        #expect(file.hunks[0].context == "fn ctx")
        #expect(file.hunks[0].collapsedBefore == 2)
        #expect(file.hunks[1].collapsedBefore == 21 - 1 - 6) // new side ended at line 6
        #expect((file.additions, file.deletions) == (3, 2))
        let second = file.hunks[1].lines.map { diff.lines[$0] }
        #expect(second.map(\.kind) == [.deletion, .addition, .context])
        #expect(diff.text(second[0]) == "-- a deleted line that looks like a header")
        #expect(second[2].noNewline && !second[1].noNewline)
        #expect((second[2].oldNumber, second[2].newNumber) == (21, 22))
    }

    @Test func renamesBinariesModesAndQuotedPaths() {
        let patch = """
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt
        diff --git a/src/x.swift b/src/y.swift
        similarity index 80%
        rename from src/x.swift
        rename to src/y.swift
        --- a/src/x.swift
        +++ b/src/y.swift
        @@ -1 +1 @@
        -let a = 1
        +let a = 2
        diff --git a/img.png b/img.png
        new file mode 100644
        index 0000000..1234567
        Binary files /dev/null and b/img.png differ
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git "a/caf\\303\\251 \\"q\\".md" "b/caf\\303\\251 \\"q\\".md"
        deleted file mode 100644
        --- "a/caf\\303\\251 \\"q\\".md"
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two

        """
        let diff = UnifiedDiff(patch)
        #expect(diff.files.map(\.path) == ["new name.txt", "src/y.swift", "img.png", "run.sh", "caf\u{e9} \"q\".md"])
        #expect(diff.files.map(\.change) == [.renamePure, .renameChanged, .new, .change, .deleted])
        #expect(diff.files[0].oldPath == "old name.txt")
        #expect(diff.files[1].hunks[0].oldCount == 1 && diff.files[1].hunks[0].newCount == 1)
        #expect(diff.files[2].isBinary && diff.files[2].hunks.isEmpty)
        #expect(diff.files[3].hunks.isEmpty)
        #expect(diff.files[4].deletions == 2 && diff.files[4].newPath == nil)
        #expect(diff.files[4].hunks[0].collapsedBefore == 0)
    }

    @Test func plainUnifiedDiffAndCRLF() {
        let diff = UnifiedDiff("--- a/x.txt\t2024-01-01\r\n+++ b/x.txt\t2024-01-02\r\n@@ -1,2 +1,2 @@\r\n a\r\n-b\r\n+c\r\n--- y.txt\n+++ y.txt\n@@ -1 +1 @@\n-1\n+2\n")
        #expect(diff.files.map(\.path) == ["x.txt", "y.txt"])
        #expect(diff.text(diff.lines[2]) == "c")
        #expect(diff.files[1].additions == 1)
    }

    @Test func emptyAndGarbage() {
        #expect(UnifiedDiff("").files.isEmpty)
        #expect(UnifiedDiff("not a patch\nat all").files.isEmpty)
        // A hunk cut short by truncation keeps what parsed.
        let cut = UnifiedDiff("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,5 +1,5 @@\n x\n-y\n")
        #expect(cut.files[0].hunks[0].lines.count == 2)
    }

    @Test func wrapBreaksLikePreWrap() {
        #expect(DiffLayout.wrapBreaks("short", columns: 10) == [])
        #expect(DiffLayout.wrapBreaks("aaaa bbbb cccc", columns: 10) == [10])
        #expect(DiffLayout.wrapBreaks("abcdefghijklmnop", columns: 5) == [5, 10, 15])
        // Trailing spaces hang instead of wrapping.
        #expect(DiffLayout.wrapBreaks("abc       ", columns: 5) == [])
        // The reference case (scripts/gen-diff-spec.py "wrap"): 52 columns at 460px unified.
        let line = "This line is long enough that it has to wrap at the panel width, so the row grows by one line height per extra visual line."
        let utf16 = Array(line.utf16)
        let cuts = [0] + DiffLayout.wrapBreaks(line, columns: 52) + [utf16.count]
        let pieces = zip(cuts, cuts.dropFirst()).map { String(decoding: utf16[$0..<$1], as: UTF16.self).trimmingCharacters(in: .whitespaces) }
        #expect(pieces == ["This line is long enough that it has to wrap at the", "panel width, so the row grows by one line height per", "extra visual line."])
    }

    /// Tabs advance two columns, so a short line of tabs can still wrap; row height must agree.
    @Test func tabIndentedLineHeightMatchesWrap() {
        let text = String(repeating: "\t", count: 20) + "x"
        let diff = UnifiedDiff("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+\(text)\n")
        #expect(DiffLayout.visualLines(diff, 0, columns: 30) == DiffLayout.wrapBreaks(text, columns: 30).count + 1)
        #expect(DiffLayout.visualLines(diff, 0, columns: 30) == 2)
    }

    /// Both sides tokenize as whole texts: a block comment opened on a context line colors the
    /// added line inside it, and deleted lines take old-side tokens.
    @Test func highlightsAcrossLines() {
        let diff = UnifiedDiff("diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1,3 +1,3 @@\n /* start\n-old text\n+const x = 1\n end */\n")
        let highlighter = DiffHighlighter(diff: diff)
        #expect(highlighter.spans(file: 0, line: 2).map(\.kind) == [.comment])
        #expect(highlighter.spans(file: 0, line: 1).map(\.kind) == [.comment])
        let plain = UnifiedDiff("diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1 +1 @@\n-let a\n+const b = 2\n")
        let kinds = DiffHighlighter(diff: plain).spans(file: 0, line: 1).map(\.kind)
        #expect(kinds.first == .storage || kinds.first == .keyword)
        #expect(kinds.contains(.constant))
    }

    @Test func splitPairsAlignChangeBlocks() {
        let diff = UnifiedDiff("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,4 +1,3 @@\n c\n-d1\n-d2\n-d3\n+a1\n")
        let pairs = DiffLayout.splitPairs(diff, diff.files[0].hunks[0].lines)
        #expect(pairs.map { [$0.0, $0.1] } == [[0, 0], [1, 4], [2, -1], [3, -1]])
    }

    /// The changed files card's call: the panel asks for exactly that run's delta (the first run
    /// through getFullThreadDiff), shows it collapsed and scrolls to the file without opening it
    /// (T3 only scrolls for turn diffs; reference 48).
    @Test func panelLoadsRunAndRevealsFile() async throws {
        actor Requests { var all: [TurnDiffs.Request] = []; func add(_ r: TurnDiffs.Request) { all.append(r) } }
        let requests = Requests()
        let patch = try Self.recordedPatch()
        let panel = DiffPanelView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        panel.threadId = "t1"
        panel.loader = { request in
            await requests.add(request)
            let json = try JSONSerialization.data(withJSONObject: ["threadId": "t1", "fromTurnCount": 0, "toTurnCount": 1, "diff": patch])
            return try JSONDecoder().decode(ThreadTurnDiff.self, from: json)
        }
        func summary(_ run: String, _ count: Int) -> TurnDiffSummary {
            TurnDiffSummary(checkpointId: CheckpointId(run), scopeId: "scope", runId: RunId(run), checkpointTurnCount: count, checkpointRef: "ref",
                            status: "ready", files: [], assistantMessageId: nil, completedAt: T3Timestamp(stringLiteral: "2026-10-10T00:00:0\(count)Z"))
        }
        panel.open(runId: "run1", filePath: "notes.md") // before the summaries, like a fresh timeline
        panel.setSummaries([summary("run2", 2), summary("run1", 1)])
        for _ in 0..<100 where panel.list.diff.files.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await requests.all.last == .fullThread(GetFullThreadDiffInput(threadId: "t1", toTurnCount: 1, ignoreWhitespace: true)))
        #expect(panel.list.diff.files.map(\.path) == ["hello.py", "notes.md"])
        #expect(panel.list.collapsed == [0]) // scrolled to and expanded
        panel.open(runId: "run2", filePath: nil)
        for _ in 0..<100 where await requests.all.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await requests.all.last == .turn(GetTurnDiffInput(threadId: "t1", fromTurnCount: 1, toTurnCount: 2, ignoreWhitespace: true)))
    }

    /// T3's git scopes (DiffPanel.tsx:289-412): with a git loader the panel opens on Changes (the branch range),
    /// Uncommitted reads the working tree, a turn open leaves the git scopes, and a generic open comes back.
    @Test func panelShowsGitScopes() async throws {
        actor Calls { var all: [(String, String?)] = []; func add(_ c: (String, String?)) { all.append(c) } }
        let calls = Calls()
        let file: @Sendable (String) -> String = { name in "diff --git a/\(name) b/\(name)\n--- a/\(name)\n+++ b/\(name)\n@@ -1 +1 @@\n-a\n+b\n" }
        let panel = DiffPanelView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        panel.workspaceRoot = "/repo"
        panel.gitLoader = { cwd, baseRef, _ in
            await calls.add((cwd, baseRef))
            return ReviewDiffPreview(cwd: cwd, sources: [
                .init(id: "w", kind: "working-tree", title: "Uncommitted", baseRef: nil, headRef: nil, diff: file("dirty.txt"), diffHash: "1", truncated: false),
                .init(id: "b", kind: "branch-range", title: "Changes", baseRef: "origin/main", headRef: "feature", diff: file("branch.txt"), diffHash: "2", truncated: false),
            ])
        }
        panel.threadId = "t1"
        #expect(panel.gitScope == .branch)
        panel.setSummaries([])
        for _ in 0..<100 where panel.list.diff.files.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.list.diff.files.map(\.path) == ["branch.txt"])
        #expect(await calls.all.first?.0 == "/repo")
        panel.selectGitScope(.unstaged)
        for _ in 0..<100 where panel.list.diff.files.first?.path != "dirty.txt" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.list.diff.files.map(\.path) == ["dirty.txt"])
        panel.open(runId: nil, filePath: nil)
        #expect(panel.gitScope == nil)
        panel.selectGitScope(.branch)
        #expect(panel.gitScope == .branch)
        let local = VcsRef(name: "main"), origin = VcsRef(name: "origin/main", isRemote: true, remoteName: "origin")
        let fork = VcsRef(name: "fork/main", isRemote: true, remoteName: "fork"), only = VcsRef(name: "origin/release", isRemote: true, remoteName: "origin")
        let choices = DiffBaseRefChoice.build(local: [local], remote: [fork, origin, only])
        #expect(choices.map(\.label) == ["main", "fork/main", "origin/release"])
        #expect(choices[0].remote == origin)
        #expect(choices[0].value(selected: "origin/main") == "origin/main")
        #expect(choices[0].value(selected: nil) == "main")
    }

    /// Resizing an annotation keeps the reader's line in place instead of jumping to the file header.
    @Test func reloadAnnotationsKeepsScrollPosition() {
        final class Card: NSView, DiffAnnotationContent {
            var height: CGFloat = 40
            func height(forWidth width: CGFloat) -> CGFloat { height }
        }
        var patch = "diff --git a/big.ts b/big.ts\nnew file mode 100644\n--- /dev/null\n+++ b/big.ts\n@@ -0,0 +1,2000 @@\n"
        for i in 0..<2_000 { patch += "+let v\(i) = \(i)\n" }
        let list = DiffListView()
        let card = Card()
        list.annotationView = { _ in card }
        let scroll = ScrollAreaView(documentView: list)
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 800)
        list.setDiff(UnifiedDiff(patch), collapsedByDefault: false)
        list.annotations = [DiffAnnotation(path: "big.ts", right: true, line: 1_500, id: "c")]
        scroll.layoutSubtreeIfNeeded()
        scroll.scroll(to: NSPoint(x: 0, y: 10_007))
        let origin = scroll.scrollView.contentView.bounds.origin
        #expect(origin.y == 10_007)
        list.reloadAnnotations()
        #expect(scroll.scrollView.contentView.bounds.origin == origin)
        card.height = 400 // below the viewport
        list.reloadAnnotations()
        #expect(scroll.scrollView.contentView.bounds.origin == origin)
        list.annotations = [DiffAnnotation(path: "big.ts", right: true, line: 10, id: "c")]
        scroll.scroll(to: NSPoint(x: 0, y: 10_007))
        card.height = 100 // above the viewport: the content above shrinks by 300pt
        list.reloadAnnotations()
        #expect(abs(scroll.scrollView.contentView.bounds.origin.y - (10_007 - 300)) < 0.01)
    }

    /// A 20,000-line diff in one expanded file: layout is a flat array, and the list only builds
    /// views for rows near the viewport.
    @Test func largeDiffStaysVirtual() throws {
        var patch = "diff --git a/big.ts b/big.ts\nnew file mode 100644\n--- /dev/null\n+++ b/big.ts\n@@ -0,0 +1,20000 @@\n"
        for i in 0..<20_000 { patch += "+export const value\(i) = \"\(String(repeating: "x", count: i % 90))\"; // line \(i)\n" }
        let start = Date()
        let diff = UnifiedDiff(patch)
        let parseTime = Date().timeIntervalSince(start)
        #expect(diff.lines.count == 20_000)
        let list = DiffListView()
        let scroll = ScrollAreaView(documentView: list)
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 800)
        list.setDiff(diff, collapsedByDefault: false)
        scroll.layoutSubtreeIfNeeded()
        let layoutStart = Date()
        _ = DiffLayout(diff: diff, collapsed: [], style: .unified, width: 460, wrap: true, ch: DiffStyle.ch)
        let layoutTime = Date().timeIntervalSince(layoutStart)
        #expect(list.rowLayout.rows.count == 20_002) // header, 20,000 lines, the 8px footer
        #expect(list.frame.height > 400_000) // wrapped rows are taller than 20px
        #expect(list.liveRowViews < 70, "\(list.liveRowViews) row views for an 800pt viewport")
        scroll.scroll(to: NSPoint(x: 0, y: 200_000))
        list.tile()
        #expect(list.liveRowViews < 70)
        #expect(list.createdRowViews < 140)
        print("20k-line diff: parse \(Int(parseTime * 1000)) ms, layout \(Int(layoutTime * 1000)) ms, \(list.createdRowViews) views made")
        print("20k-line diff: patch \(patch.utf8.count / 1024) KB, lines \(diff.lines.count * MemoryLayout<UnifiedDiff.Line>.stride / 1024) KB, rows \(list.rowLayout.rows.count * MemoryLayout<DiffLayout.Row>.stride / 1024) KB")
    }
}
