import AppKit
import Testing
@testable import Features

/// #33989, #34607, #34662: the cases of 4928 packages/shared/src/pullRequestAnchor.test.ts.
struct PullRequestAnchorTests {
    typealias A = PullRequestAnchor
    static let url = "https://github.com/owner/repo/pull/7"
    static let gitlab = "https://gitlab.com/group/repo/-/merge_requests/7"

    @Test(arguments: ["discussion_r123", "r123", "discussion-diff-123R5-L9", "discussion-diff-123"])
    func reviewCommentAliases(_ hash: String) {
        #expect(A.parse("\(Self.url)#\(hash)") == .timeline("discussion_r123"))
        #expect(A.matches("discussion_r123", url: "\(Self.url)#\(hash)"))
    }

    @Test(arguments: ["pullrequestreview-123", "issuecomment-123", "commitcomment-123", "event-123", "note_123", "comment-123"])
    func timelineAnchors(_ anchor: String) {
        #expect(A.parse("\(Self.url)#\(anchor)") == .timeline(anchor))
    }

    @Test(arguments: [String(repeating: "a", count: 32), String(repeating: "b", count: 64)])
    func fileAndLineRanges(_ digest: String) {
        #expect(A.parse("\(Self.url)/files#diff-\(digest)") == .diff(digest: digest, range: nil))
        #expect(A.parse("\(Self.url)/changes#diff-\(digest)L12-R15") == .diff(digest: digest, range: .init(start: 12, side: "left", end: 15, endSide: "right")))
        #expect(A.parse("\(Self.url)#diff-\(digest)R42") == .diff(digest: digest, range: .init(start: 42, side: "right", end: 42, endSide: "right")))
    }

    @Test func pathDigests() {
        let cases = [("src/hello world.ts", "bcea8deb9d67b305e28c4a0b0d021615", "066802cf2cf056706e4e4951cb7dff2717a2ae32fd9797c1f1b41062d57db929"),
                     ("src/日本語.ts", "5c66d5d565666e46924cf80d7bbfdab3", "191b8ebf2241225db999eaf8b6ff44b07934d577f347d0ff684591eecad34944"),
                     ("old/path.ts", "f5d455478d496859b654884654393a61", "aa38d67014e2c59d51ea456a155e039f4e32f636a4c450714c3b517bb8bde7e7")]
        for (path, legacy, current) in cases {
            for digest in [legacy, current] {
                #expect(A.pathMatches(digest, path))
                #expect(!A.pathMatches(digest, "other.ts"))
            }
        }
    }

    @Test func encodedAndInvalid() {
        #expect(A.parse("\(Self.url)#%64iscussion_r123") == .timeline("discussion_r123"))
        #expect(A.parse("\(Self.url)#diff-abcR0") == nil)
        #expect(A.parse("\(Self.url)#diff-abcR9999999999999999999") == nil)
        #expect(A.parse("invalid") == nil)
        #expect(A.parse(Self.url) == nil)
        #expect(A.parse("\(Self.url)#unknown") == .summary("unknown"))
        #expect(A.parse("\(Self.url)/files-not-a-tab") == nil)
        #expect(A.parse("\(Self.url)/commits/main") == nil)
        #expect(A.parse("\(Self.url)/checks/extra") == nil)
    }

    @Test func commitScope() {
        let sha = String(repeating: "a", count: 40)
        #expect(A.linkCommit("\(Self.url)/commits/\(sha)#diff-abcR5") == sha)
        #expect(A.linkCommit("\(Self.url)/files#diff-abcR5") == nil)
        #expect(A.linkCommit("\(Self.gitlab)/diffs?commit_id=\(sha)") == sha)
    }

    @Test func tabsKeepUnknownHashes() {
        let sha = String(repeating: "a", count: 40)
        let cases: [(String, A)] = [("\(Self.url)/files", .code), ("\(Self.url)/files/", .code), ("\(Self.url)/changes", .code),
                                    ("\(Self.url)/commits/\(sha)", .code), ("\(Self.url)/commits", .commits), ("\(Self.url)/checks?check_run_id=1", .checks),
                                    ("\(Self.gitlab)/diffs", .code), ("\(Self.gitlab)/commits", .commits), ("\(Self.gitlab)/pipelines", .checks)]
        for (path, kind) in cases {
            for hash in ["", "#unknown", "#diff-abcR0", "#diff-abcR9999999999999999999"] {
                #expect(A.parse(path + hash) == kind, "\(path)\(hash)")
            }
            #expect(A.parse("\(path)#issuecomment-123") == .timeline("issuecomment-123"))
        }
    }

    @Test func gitLabLineCodes() {
        let sha1 = String(repeating: "c", count: 40)
        #expect(A.parse("\(Self.gitlab)/diffs#\(sha1)_4_6") == .diff(digest: sha1, range: .init(start: 6, side: "right", end: 6, endSide: "right", oldLine: 4)))
        #expect(A.parse("\(Self.gitlab)/diffs#\(sha1)_4_0") == .diff(digest: sha1, range: .init(start: 4, side: "left", end: 4, endSide: "left")))
        #expect(A.parse("\(Self.gitlab)/diffs#line_abcdef012_A9") == .diff(digest: "abcdef012", range: .init(start: 9, side: "right", end: 9, endSide: "right")))
        #expect(A.parse("\(Self.gitlab)/diffs?file=\(sha1)") == .diff(digest: sha1, range: nil))
        let r = A.Range(start: 6, side: "right", end: 6, endSide: "right", oldLine: 4)
        #expect(A.resolve(r) { $0 == 4 } == .init(start: 4, side: "left", end: 4, endSide: "left"))
        #expect(A.resolve(r) { _ in false } == r)
    }

    @Test func reviewWithoutWordsFindsItsFirstComment() {
        let review = "\(Self.url)#pullrequestreview-9"
        let threads: [(url: String?, createdAt: String, reviewUrl: String?)] = [
            ("\(Self.url)#discussion_r3", "2026-07-01T00:02:00Z", review),
            ("\(Self.url)#discussion_r2", "2026-07-01T00:01:00Z", review),
            ("\(Self.url)#discussion_r1", "2026-07-01T00:00:00Z", nil)]
        #expect(A.resolveReview("pullrequestreview-9", commentURLs: [], threadComments: threads) == "discussion_r2")
        #expect(A.resolveReview("pullrequestreview-9", commentURLs: [review], threadComments: threads) == "pullrequestreview-9")
        #expect(A.resolveReview("pullrequestreview-8", commentURLs: [], threadComments: threads) == "pullrequestreview-8")
        #expect(A.resolveReview("issuecomment-9", commentURLs: [], threadComments: threads) == "issuecomment-9")
    }
}

/// The panel follows a link: the tab it names, and the linked comment marked in the Timeline.
@MainActor
struct PullRequestLinkJumpTests {
    @Test func linksSelectTheirTab() throws {
        let panel = PullRequestDetailView()
        panel.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        let d = try PullRequestFixtures.detail()
        panel.show(d)
        panel.activityPending = false
        #expect(panel.reveal(url: d.url + "/checks") == nil)
        #expect(panel.tab == .summary)
        let sha = String(repeating: "a", count: 40)
        #expect(panel.reveal(url: d.url + "/commits/\(sha)#diff-abcR5") == sha)
        #expect(panel.tab == .code)
        panel.reveal(url: d.url + "/commits")
        #expect(panel.tab == .timeline)
        panel.reveal(url: d.url + "#issuecomment-1")
        #expect(panel.tab == .timeline)
        #expect(PullRequestDetailView.linkedTab(nil) == nil)
        #expect(panel.reveal(url: d.url) == nil)
    }
}
