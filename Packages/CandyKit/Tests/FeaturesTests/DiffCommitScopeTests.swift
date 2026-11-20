import AppKit
import Testing
import T3Protocol
@testable import Features

/// #19941: the diff panel reviews one local commit (4928 DiffPanel.tsx:328-460, 938-1037).
@MainActor
struct DiffCommitScopeTests {
    @Test func commitScopeReadsThatCommit() async throws {
        actor Calls { var shas: [String] = []; func add(_ s: String) { shas.append(s) } }
        let calls = Calls()
        let file: @Sendable (String) -> String = { name in "diff --git a/\(name) b/\(name)\n--- a/\(name)\n+++ b/\(name)\n@@ -1 +1 @@\n-a\n+b\n" }
        let panel = DiffPanelView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        panel.workspaceRoot = "/repo"
        panel.gitLoader = { cwd, _, _ in
            ReviewDiffPreview(cwd: cwd, sources: [.init(id: "b", kind: "branch-range", title: "Changes", baseRef: "main", headRef: "feature", diff: file("branch.txt"), diffHash: "2", truncated: false)])
        }
        let sha = String(repeating: "a", count: 40)
        panel.commitLoader = { cwd, sha, _, _ in
            await calls.add(sha)
            var source = ReviewDiffPreview.Source(id: "c", kind: "commit", title: "Commit", baseRef: nil, headRef: sha, diff: file("one.txt"), diffHash: "3", truncated: false)
            source.commitSubject = "Fix the thing"
            return ReviewDiffPreview(cwd: cwd, sources: [source])
        }
        panel.branchCommitsLoader = { _, _ in
            ReviewBranchCommits(commits: [.init(sha: sha, subject: "Fix the thing", committedAt: "2026-11-01T00:00:00Z")], truncated: false)
        }
        panel.threadId = "t1"
        panel.setSummaries([])
        _ = await eventually { panel.list.diff.files.first?.path == "branch.txt" }
        _ = await eventually { panel.commitsMenuForTesting.map { if case .submenu(let rows) = $0.kind { rows.count == 1 && rows[0].title == "Fix the thing" } else { false } } ?? false }
        panel.selectGitScope(.commit(sha))
        _ = await eventually { panel.list.diff.files.first?.path == "one.txt" }
        #expect(panel.list.diff.files.map(\.path) == ["one.txt"])
        #expect(await calls.shas == [sha])
        #expect(panel.scopeTitle == "Fix the thing")
    }

    /// A thread switch while the git diff loads cancels that load; the next thread must still load its own
    /// (screen pass 3: a restored Diff panel stayed empty until Refresh).
    @Test func threadSwitchDuringALoadStillLoadsTheNewThread() async throws {
        let file: @Sendable (String) -> String = { name in "diff --git a/\(name) b/\(name)\n--- a/\(name)\n+++ b/\(name)\n@@ -1 +1 @@\n-a\n+b\n" }
        let panel = DiffPanelView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        panel.workspaceRoot = "/one"
        panel.gitLoader = { cwd, _, _ in
            if cwd == "/one" { try await Task.sleep(for: .milliseconds(300)) }
            return ReviewDiffPreview(cwd: cwd, sources: [.init(id: "b", kind: "branch-range", title: "Changes", baseRef: "main", headRef: "main",
                                                               diff: file(cwd == "/one" ? "one.txt" : "two.txt"), diffHash: cwd, truncated: false)])
        }
        panel.threadId = "t1"
        panel.setSummaries([])
        panel.workspaceRoot = "/two"
        panel.threadId = "t2"
        panel.setSummaries([])
        #expect(await eventually(seconds: 5) { panel.list.diff.files.first?.path == "two.txt" })
    }

    @Test func oldServersShowNoCommitsMenu() async throws {
        struct Refused: LocalizedError { var errorDescription: String? { "Unknown method" } }
        let panel = DiffPanelView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        panel.workspaceRoot = "/repo"
        panel.gitLoader = { cwd, _, _ in ReviewDiffPreview(cwd: cwd, sources: []) }
        panel.branchCommitsLoader = { _, _ in throw Refused() }
        panel.threadId = "t1"
        panel.setSummaries([])
        #expect(await eventually(seconds: 5) { panel.commitsMenuForTesting == nil })
    }
}

/// #28244: the Changes and PR Code lists start at a responsive width and keep a chosen one
/// (4928 FileExplorerPane.browser.test.tsx).
@MainActor
struct FileListWidthTests {
    @Test func initialWidthsInANarrowRow() {
        #expect(FileListWidth.bounds(row: 420, .changes).initial == 168)
        #expect(FileListWidth.bounds(row: 420, .pullRequestCode).initial == 192)
        #expect(FileListWidth.bounds(row: 1000, .changes).initial == 256)
        #expect(FileListWidth.bounds(row: 1000, .pullRequestCode).initial == 320)
        // The default never shrinks to leave the diff its 256.
        #expect(FileListWidth.bounds(row: 420, .changes).max == 168)
        #expect(FileListWidth.bounds(row: 2000, .changes).max == 560)
    }

    @Test func savedWidthIsClampedToTheRow() {
        #expect(FileListWidth.width(row: 1000, .changes, saved: 400) == 400)
        #expect(FileListWidth.width(row: 1000, .changes, saved: 900) == 560)
        #expect(FileListWidth.width(row: 1000, .pullRequestCode, saved: 100) == 192)
        #expect(FileListWidth.width(row: 1000, .changes, saved: nil) == 256)
    }

    @Test func paneSitsOnTheRightAndTheHandleResizesIt() {
        let saved = FileListWidth.saved
        defer { FileListWidth.saved = saved }
        FileListWidth.saved = nil
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let pane = FileListPane(sizing: .changes, resizeLabel: "Resize Changes files", listLabel: "Changes files")
        host.addSubview(pane)
        #expect(pane.place(in: host.bounds, host: host) == 256)
        #expect(pane.frame.minX == 744)
        #expect(pane.handle.frame.midX == 744)
        #expect(pane.handle.accessibilityRole() == .splitter)
        pane.handle.onResize?(300)
        pane.handle.onCommit?()
        #expect(FileListWidth.saved == 300)
        #expect(pane.width(row: 1000) == 300)
    }
}
