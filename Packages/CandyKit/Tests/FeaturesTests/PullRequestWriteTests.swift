import Foundation
import Testing
@testable import T3Protocol
@testable import Features

/// WP7.5c: the payload of every pull request write RPC (pullRequest.ts:1073-1262, git.ts:169) and the
/// logic ported from pullRequestEditing.logic.ts, pullRequestReactions.logic.ts, PullRequestStackMenu.tsx,
/// the composer forms, the condensed header and the list paging.
struct PullRequestWriteTests {
    static let ref = PullRequestRef(projectId: "p1", host: "github.com", repository: "o/r", number: 7)

    static func obj(_ v: JSONValue?) -> [String: JSONValue] { v?.objectValue ?? [:] }

    // MARK: Payloads

    @Test func runActionCarriesTheStackFields() {
        let p = Self.obj(PullRequestPayloads.action(Self.ref, action: "merge", mergeMethod: "squash", stackNumber: 3,
                                                     expectedStackHeads: [(1, "aaa"), (2, "bbb")]))
        #expect(p["action"] == .string("merge") && p["mergeMethod"] == .string("squash") && p["stackNumber"] == .number(3))
        #expect(p["expectedStackHeads"] == .array([.object(["number": .number(1), "headSha": .string("aaa")]),
                                                   .object(["number": .number(2), "headSha": .string("bbb")])]))
        #expect(p["host"] == .string("github.com") && p["number"] == .number(7) && p["projectId"] == .string("p1"))
        let plain = Self.obj(PullRequestPayloads.action(Self.ref, action: "close"))
        #expect(plain["stackNumber"] == nil && plain["expectedStackHeads"] == nil && plain["mergeMethod"] == nil)
    }

    @Test func commentUpdateReplyAndResolution() {
        #expect(PullRequestPayloads.comment(Self.ref, body: "  ") == nil)
        #expect(Self.obj(PullRequestPayloads.comment(Self.ref, body: "  keep leading"))["body"] == .string("  keep leading"))
        #expect(PullRequestPayloads.comment(Self.ref, body: String(repeating: "a", count: 65_537)) == nil)
        let title = Self.obj(PullRequestPayloads.update(Self.ref, title: "  New title "))
        #expect(title["title"] == .string("New title") && title["body"] == nil)
        #expect(PullRequestPayloads.update(Self.ref, title: "   ") == nil)
        #expect(Self.obj(PullRequestPayloads.update(Self.ref, body: ""))["body"] == .string(""))
        let edit = Self.obj(PullRequestPayloads.updateComment(Self.ref, commentId: "IC_2", kind: "issue-comment", body: "fixed"))
        #expect(edit["commentId"] == .string("IC_2") && edit["kind"] == .string("issue-comment") && edit["body"] == .string("fixed"))
        #expect(PullRequestPayloads.updateComment(Self.ref, commentId: "R", kind: "review", body: "x") == nil)
        let reply = Self.obj(PullRequestPayloads.replyToThread(Self.ref, threadId: "RT_1", body: "Done"))
        #expect(reply["threadId"] == .string("RT_1") && reply["body"] == .string("Done"))
        #expect(PullRequestPayloads.replyToThread(Self.ref, threadId: "RT_1", body: "\n") == nil)
        let resolve = Self.obj(PullRequestPayloads.setThreadResolution(Self.ref, threadId: "RT_1", resolved: true))
        #expect(resolve["resolved"] == .bool(true))
        let page = Self.obj(PullRequestPayloads.threadComments(Self.ref, threadId: "RT_1", cursor: "c2"))
        #expect(page["cursor"] == .string("c2"))
    }

    @Test func reviewWithLineComments() {
        let drafts = [
            PullRequestReviewCommentDraft(id: "pending-1", path: "a.ts", position: .added(newLine: 4), body: "why?"),
            PullRequestReviewCommentDraft(id: "pending-2", path: "b.ts", oldPath: "old/b.ts", position: .context(oldLine: 2, newLine: 3, side: "left"), body: "ok"),
            PullRequestReviewCommentDraft(id: "pending-3", path: "c.ts", oldPath: "c.ts", position: .deleted(oldLine: 9), body: "gone"),
        ]
        let p = Self.obj(PullRequestPayloads.submitReview(Self.ref, verdict: "request-changes", body: "", comments: drafts))
        #expect(p["verdict"] == .string("request-changes") && p["body"] == .string(""))
        guard case .array(let c)? = p["comments"] else { Issue.record("no comments"); return }
        #expect(c.count == 3)
        #expect(c[0] == .object(["path": .string("a.ts"), "body": .string("why?"), "position": .object(["kind": .string("added"), "newLine": .number(4)])]))
        #expect(Self.obj(c[1])["oldPath"] == .string("old/b.ts"))
        #expect(Self.obj(Self.obj(c[1])["position"])["side"] == .string("left"))
        // The same name is not sent twice, and the local id never goes.
        #expect(Self.obj(c[2])["oldPath"] == nil && Self.obj(c[2])["id"] == nil)
        #expect(drafts[1].position.anchor == ("left", 2))
        #expect(drafts[0].position.anchor == ("right", 4))
    }

    @Test func reactionsReviewersAndLabels() {
        let r = Self.obj(PullRequestPayloads.setReaction(Self.ref, subjectId: "IC_1", content: "heart", reacted: true))
        #expect(r["subjectId"] == .string("IC_1") && r["content"] == .string("heart") && r["reacted"] == .bool(true))
        #expect(Self.obj(PullRequestPayloads.setReaction(Self.ref, subjectId: nil, content: "eyes", reacted: false))["subjectId"] == nil)
        #expect(PullRequestPayloads.setReaction(Self.ref, subjectId: nil, content: "+1", reacted: true) == nil)
        let rev = Self.obj(PullRequestPayloads.requestReviewers(Self.ref, reviewers: [("U_1", "user"), ("T_1", "team")], requested: false))
        #expect(rev["reviewers"] == .array([.object(["id": .string("U_1"), "kind": .string("user")]), .object(["id": .string("T_1"), "kind": .string("team")])]))
        #expect(rev["requested"] == .bool(false))
        #expect(PullRequestPayloads.requestReviewers(Self.ref, reviewers: [], requested: true) == nil)
        #expect(PullRequestPayloads.requestReviewers(Self.ref, reviewers: Array(repeating: ("U", "user"), count: 26), requested: true) == nil)
        #expect(PullRequestPayloads.requestReviewers(Self.ref, reviewers: [("U", "bot")], requested: true) == nil)
        let labels = Self.obj(PullRequestPayloads.setLabels(Self.ref, labels: [" bug "], applied: true))
        #expect(labels["labels"] == .array([.string("bug")]) && labels["applied"] == .bool(true))
        #expect(PullRequestPayloads.setLabels(Self.ref, labels: [" "], applied: true) == nil)
    }

    @Test func checkoutIntoAThread() {
        let worktree = Self.obj(PullRequestPayloads.preparePullRequestThread(cwd: "/repo", reference: "42", mode: "worktree", threadId: "t1"))
        #expect(worktree == ["cwd": .string("/repo"), "reference": .string("42"), "mode": .string("worktree"), "threadId": .string("t1")])
        // Local never carries the thread.
        #expect(Self.obj(PullRequestPayloads.preparePullRequestThread(cwd: "/repo", reference: "42", mode: "local", threadId: "t1"))["threadId"] == nil)
        #expect(PullRequestPayloads.preparePullRequestThread(cwd: " ", reference: "42", mode: "local", threadId: nil) == nil)
        #expect(Self.obj(PullRequestPayloads.resolvePullRequest(cwd: "/repo", reference: "#42")) == ["cwd": .string("/repo"), "reference": .string("#42")])
        let prepared = try? JSONDecoder().decode(GitPreparePullRequestThreadResult.self, from: Data(#"{"pullRequest":{"number":42,"title":"T","url":"u","baseBranch":"main","headBranch":"f","state":"open"},"branch":"f","worktreePath":null}"#.utf8))
        #expect(prepared?.isOnPullRequestHead == true && prepared?.worktreePath == nil)
        #expect(PullRequestWriteLogic.checkoutValidation("", dirty: true) == "Paste a pull request URL, checkout command, or enter 123 / #123.")
        #expect(PullRequestWriteLogic.checkoutValidation("not a ref", dirty: true) == "Use a pull request URL, checkout command, 123, or #123.")
        #expect(PullRequestWriteLogic.checkoutValidation("#12", dirty: true) == nil)
        #expect(PullRequestWriteLogic.checkoutValidation("", dirty: false) == nil)
    }

    // MARK: Logic

    @Test func editing() throws {
        var d = try PullRequestFixtures.detail()
        #expect(PullRequestWriteLogic.canEditChangeRequest(d))
        d.viewer = "someone"
        #expect(PullRequestWriteLogic.canEditChangeRequest(d)) // may merge
        d.viewerPermissions.actions = []
        #expect(!PullRequestWriteLogic.canEditChangeRequest(d))
        d.viewer = "OctoCat "
        #expect(PullRequestWriteLogic.canEditChangeRequest(d))
        #expect(PullRequestWriteLogic.canEditComment(d, author: "octocat", kind: "issue-comment"))
        #expect(!PullRequestWriteLogic.canEditComment(d, author: "octocat", kind: "review"))
        #expect(!PullRequestWriteLogic.canEditComment(d, author: "hubot", kind: "review-comment"))
        #expect(PullRequestWriteLogic.titleToSave("  Same ", current: "Same") == nil)
        #expect(PullRequestWriteLogic.titleToSave(" New ", current: "Old") == "New")
    }

    @Test func reactions() {
        let r = PullRequestReaction(content: "heart", count: 5, actors: ["a", "b", "c", "d"], viewerHasReacted: true)
        #expect(PullRequestReactions.tooltip(r) == "You, a, b, and 2 others reacted with heart emoji")
        #expect(PullRequestReactions.tooltip(PullRequestReaction(content: "thumbs-up", count: 2, actors: [], viewerHasReacted: false))
                == "2 people reacted with thumbs up emoji")
        // A host that already names the viewer gets no extra "You".
        #expect(PullRequestReactions.tooltip(PullRequestReaction(content: "eyes", count: 2, actors: ["me", "x"], viewerHasReacted: true))
                == "me and x reacted with eyes emoji")
        let base = [PullRequestReaction(content: "laugh", count: 1, actors: [], viewerHasReacted: true),
                    PullRequestReaction(content: "thumbs-up", count: 2, actors: [], viewerHasReacted: false)]
        let shown = PullRequestReactions.applyPending(base, ["laugh": false, "rocket": true, "thumbs-up": true])
        #expect(shown.map(\.content) == ["thumbs-up", "rocket"])
        #expect(shown[0].count == 3 && shown[0].viewerHasReacted)
        #expect(PullRequestReactions.signature(base) == "laugh:1:1 thumbs-up:2:0")
    }

    static func stack(_ states: [(String, Bool, String?)]) -> PullRequestStackDetail {
        PullRequestStackDetail(id: "s", number: 9, url: "u", base: "main", layers: states.enumerated().map { i, s in
            PullRequestStackDetail.Layer(number: i + 1, title: "L\(i + 1)", isDraft: s.1, headSha: s.2, headBranch: "b\(i + 1)", state: s.0)
        })
    }

    @Test func stackPlanAndPayload() {
        let s = Self.stack([("merged", false, "a"), ("open", false, "b"), ("open", false, "c")])
        let plan = PullRequestWriteLogic.stackPlan(s, current: 2, pending: false)
        #expect(plan.position == 2 && plan.mergeLayers.map(\.number) == [2] && plan.unmerged.map(\.number) == [2, 3])
        #expect(!plan.mergeDisabled && !plan.rebaseDisabled && plan.selectedIsOpen)
        var ref = Self.ref; ref.number = 2
        let merge = Self.obj(PullRequestWriteLogic.stackActionPayload(s, ref: ref, action: "merge", mergeMethod: "squash"))
        #expect(merge["number"] == .number(2) && merge["stackNumber"] == .number(9) && merge["mergeMethod"] == .string("squash"))
        #expect(merge["expectedStackHeads"] == .array([.object(["number": .number(2), "headSha": .string("b")])]))
        let rebase = Self.obj(PullRequestWriteLogic.stackActionPayload(s, ref: ref, action: "update-branch", mergeMethod: "squash"))
        #expect(rebase["number"] == .number(3) && rebase["updateMethod"] == .string("rebase") && rebase["mergeMethod"] == nil)
        guard case .array(let heads)? = rebase["expectedStackHeads"] else { Issue.record("heads"); return }
        #expect(heads.count == 2)
        let draft = PullRequestWriteLogic.stackPlan(Self.stack([("open", true, "a"), ("open", false, "b")]), current: 2, pending: false)
        #expect(draft.mergeDisabled && draft.showsReadyNote)
        let unknown = PullRequestWriteLogic.stackPlan(Self.stack([("open", false, nil), ("open", false, "b")]), current: 2, pending: false)
        #expect(unknown.mergeDisabled && unknown.rebaseDisabled)
        #expect(PullRequestWriteLogic.stackConfirmation(s, current: 2, action: "merge", mergeMethod: "squash").title == "Merge 1 pull requests?")
        #expect(PullRequestWriteLogic.stackLayerLines(s.layers[1], compact: false) == ("L2", "#2 · b2 · Open"))
        #expect(PullRequestWriteLogic.stackLayerLines(s.layers[0], compact: true).detail == "#1 · Merged")
        #expect(!PullRequestWriteLogic.allowsSingleMerge(supportsStackActions: true, hasStack: false, stackPending: true, stackError: false))
        #expect(PullRequestWriteLogic.allowsSingleMerge(supportsStackActions: false, hasStack: true, stackPending: true, stackError: true))
        #expect(PullRequestWriteLogic.stackNotice(hasData: true, isSuccess: false, isPending: false, error: true) == "Stack data may be stale. We couldn’t refresh it.")
        #expect(PullRequestWriteLogic.stackNotice(hasData: true, isSuccess: true, isPending: false, error: false) == nil)
    }

    @Test func composer() throws {
        var d = try PullRequestFixtures.detail()
        let offer = PullRequestWriteLogic.composerOffer(d)
        #expect(offer.canComment && offer.verdicts == ["comment", "approve", "request-changes"])
        #expect(PullRequestWriteLogic.composerMode(canComment: true, verdicts: offer.verdicts, reviewStarted: true) == "review")
        #expect(PullRequestWriteLogic.composerMode(canComment: false, verdicts: ["approve"], reviewStarted: false) == "review")
        #expect(PullRequestWriteLogic.canSubmitReview(verdict: "approve", body: "", pendingComments: 0, summaryRequired: false))
        #expect(!PullRequestWriteLogic.canSubmitReview(verdict: "comment", body: " ", pendingComments: 0, summaryRequired: false))
        #expect(PullRequestWriteLogic.canSubmitReview(verdict: "comment", body: "", pendingComments: 1, summaryRequired: false))
        #expect(!PullRequestWriteLogic.canSubmitReview(verdict: "request-changes", body: "", pendingComments: 2, summaryRequired: true))
        d.state = "open"
        #expect(PullRequestWriteLogic.commentFollowUp(d) == "close")
        d.state = "merged"
        #expect(PullRequestWriteLogic.commentFollowUp(d) == nil)
        #expect(PullRequestWriteLogic.composerLabel(pending: 2, reviewStarted: true, canComment: true) == "Review pull request, 2 comments pending")
        #expect(PullRequestWriteLogic.composerLabel(pending: 0, reviewStarted: false, canComment: true) == "Comment on pull request")
    }

    @Test @MainActor func reviewStore() {
        let store = PullRequestReviewStore()
        let key = PullRequestReviewStore.key(PullRequestRef(projectId: "p", host: "GitHub.com", repository: "O/R", number: 1))
        #expect(key == PullRequestReviewStore.key(PullRequestRef(projectId: "p", host: "github.com", repository: "o/r", number: 1)))
        let a = PullRequestReviewCommentDraft(id: store.nextId(), path: "a", position: .added(newLine: 1), body: "x")
        let b = PullRequestReviewCommentDraft(id: store.nextId(), path: "a", position: .added(newLine: 1), body: "x")
        #expect(a.id != b.id)
        store.add(key, a); store.add(key, b)
        store.remove(key, ids: [a.id])
        #expect(store.comments(key).map(\.id) == [b.id])
        store.setSummary(key, "draft")
        store.clearSummary(key, submitted: "older")
        #expect(store.summary(key) == "draft")
        store.clearSummary(key, submitted: "draft")
        #expect(store.summary(key).isEmpty)
    }

    @Test func threadsPickersAndLinks() throws {
        let c = { (id: String, body: String) in try JSONDecoder().decode(PullRequestThreadComment.self, from: Data(#"{"id":"\#(id)","author":null,"body":"\#(body)","createdAt":"2026-01-01T00:00:00Z"}"#.utf8)) }
        let merged = PullRequestWriteLogic.mergeThreadComments([try c("1", "a")], [try c("1", "dup"), try c("2", "b")])
        #expect(merged.map(\.id) == ["1", "2"] && merged[0].body == "a")
        #expect(PullRequestWriteLogic.editThreadComment(merged, id: "2", body: "B").last?.body == "B")
        let d = try PullRequestFixtures.detail()
        #expect(PullRequestWriteLogic.threadHead(d.reviewThreads[0], loaded: 1) == "Resolved · 1 comment")
        let labels = [PullRequestLabelCandidate(name: "bug", color: nil, description: "Broken", isApplied: false),
                      PullRequestLabelCandidate(name: "docs", color: nil, description: nil, isApplied: true)]
        #expect(PullRequestWriteLogic.filterLabels(labels, query: "BROK").map(\.name) == ["bug"])
        let people = [PullRequestReviewerCandidate(login: "ana", name: "Ana Lee", avatarUrl: nil, isBot: nil, id: "1", kind: "user", isRequested: false)]
        #expect(PullRequestWriteLogic.filterReviewers(people, query: "lee").count == 1 && PullRequestWriteLogic.filterReviewers(people, query: "zed").isEmpty)
        #expect(PullRequestWriteLogic.linkMenuItems(canOpenInPreview: false, threadLinkAction: "link-to-thread").map(\.label)
                == ["Link to thread", "Open in system browser", "Copy Link"])
        #expect(PullRequestWriteLogic.linkMenuItems(canOpenInPreview: true, threadLinkAction: nil).first?.label == "Open in integrated browser")
        #expect(PullRequestWriteLogic.previewAuthor(PullRequestActor(login: "octocat", name: "The Octocat")) == "The Octocat (@octocat)")
        #expect(PullRequestWriteLogic.previewAuthor(nil) == "ghost")
        #expect(PullRequestWriteLogic.previewTarget(url: "https://github.com/o/r/pull/3", pullRequestsEnabled: false, projects: []) == nil)
    }

    @Test func condensedHeaderAndPaging() {
        // Folds past the fold's height plus 32, refunding what leaves; reopens only at the top.
        let fold = PullRequestWriteLogic.condensed(previous: false, scrollTop: 141, foldHeight: 108, condensedRowHeight: 28)
        #expect(fold.condensed && fold.refund == -80)
        #expect(!PullRequestWriteLogic.condensed(previous: false, scrollTop: 140, foldHeight: 108, condensedRowHeight: 28).condensed)
        #expect(PullRequestWriteLogic.condensed(previous: true, scrollTop: 10, foldHeight: 108, condensedRowHeight: 28).condensed)
        #expect(!PullRequestWriteLogic.condensed(previous: true, scrollTop: 3, foldHeight: 108, condensedRowHeight: 28).condensed)
        let cursors = ["e1": ["github.com o/r": "c1"]]
        let next = PullRequestWriteLogic.loadMore(pageSize: 99, nextCursors: cursors, truncatedEnvironments: ["e1", "e2"])
        #expect(next.pageSize == 198 && next.cursors == cursors && next.regrown == ["e2"])
        #expect(PullRequestWriteLogic.loadMore(pageSize: 99, nextCursors: cursors, truncatedEnvironments: ["e1"]).pageSize == 99)
        let grow = PullRequestWriteLogic.loadMore(pageSize: 450, nextCursors: [:], truncatedEnvironments: ["e1"])
        #expect(grow.pageSize == 500 && grow.cursors == nil)
        #expect(PullRequestWriteLogic.continues("e1", cursors: cursors, regrown: []) && !PullRequestWriteLogic.continues("e3", cursors: cursors, regrown: []))
        #expect(PullRequestWriteLogic.continues("e2", cursors: cursors, regrown: ["e2"]))
        let list = Self.obj(PullRequestPayloads.list(state: "open", involvement: "all", cursors: ["github.com o/r": "c1"]))
        #expect(list["cursors"] == .object(["github.com o/r": .string("c1")]))
    }

    /// Review conversations sit under their line: the new side by `newNumber`, the old by `oldNumber`.
    @Test @MainActor func annotationRowsFollowTheirLine() {
        let patch = "diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"
        let diff = UnifiedDiff(patch)
        let anchors = [0: [DiffLayout.Anchor(right: true, line: 2, index: 0), DiffLayout.Anchor(right: false, line: 2, index: 1),
                           DiffLayout.Anchor(right: true, line: 9, index: 2)]]
        let layout = DiffLayout(diff: diff, collapsed: [], style: .unified, width: 600, wrap: true, ch: 7.8, anchors: anchors, anchorHeight: { _ in 50 })
        let kinds = layout.rows.map(\.kind)
        #expect(kinds == [.header, .line, .line, .annotation, .line, .annotation, .line, .footer])
        #expect(layout.rows[3].left == 1 && layout.rows[5].left == 0)
        let split = DiffLayout(diff: diff, collapsed: [], style: .split, width: 600, wrap: true, ch: 7.8, anchors: anchors, anchorHeight: { _ in 50 })
        #expect(split.rows.filter { $0.kind == .annotation }.map(\.left) == [0, 1])
    }
}
