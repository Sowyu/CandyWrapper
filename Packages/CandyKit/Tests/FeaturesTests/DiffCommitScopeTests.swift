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
