import Foundation
import Testing
@testable import T3Protocol

/// Decoding of every pull request payload the app reads (fixtures/pull-requests, shaped after
/// packages/contracts/src/pullRequest.ts and T3's own test data), the payloads it sends, and the
/// thread link helpers (shared/threadPullRequests.ts, changeRequestUrl.ts).
struct PullRequestWireTests {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/pull-requests") }
    static func json(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    static func value(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    @Test func decodesList() throws {
        let list = try Self.json("list.json").decode(as: PullRequestListResult.self)
        #expect(list.entries.count == 4)
        #expect(list.entries[1].stack?.size == 3)
        #expect(list.entries[0].labels.first?.color == "a2eeef")
        #expect(list.entries[3].author?.isBot == true)
        #expect(list.entries[3].checksState == nil)
        #expect(list.providers.first?.searchesOnHost == true)
        #expect(list.viewers["github.com"] == "octocat")
    }

    @Test func decodesDetailAndActivity() throws {
        var d = try Self.json("detail.json").decode(as: PullRequestDetail.self)
        #expect(d.comments.isEmpty && d.commentCount == 0)
        #expect(d.capabilities.viewedFiles == "host")
        #expect(d.capabilities.review.verdicts == ["comment", "approve", "request-changes"])
        #expect(d.mergeCapabilities.allows("squash") && !d.mergeCapabilities.allows("rebase"))
        #expect(d.checks.first?.required == true)
        let activity = try Self.json("activity.json").decode(as: PullRequestActivity.self)
        d.apply(activity)
        #expect(d.comments.count == 3 && d.commentCount == 3)
        #expect(d.comments[1].reactions?.first?.viewerHasReacted == true)
        #expect(d.reviewThreads.first?.isResolved == true)
        #expect(d.commits[1].additions == nil)
        #expect(d.commits[0].authors?.first?.login == "octocat")
    }

    @Test func decodesTheSmallReads() throws {
        let checks = try Self.value(#"{"state":"open","checks":[{"name":"ci","status":"pending","description":null,"url":null}]}"#)
            .decode(as: PullRequestChecks.self)
        #expect(checks.checks.first?.status == "pending")
        let diff = try Self.value(#"{"patch":"diff --git a/x b/x\n","truncated":true,"nextCursor":"c2","omittedFileStats":[{"path":"big.lock","additions":9000,"deletions":0}]}"#)
            .decode(as: PullRequestDiffResult.self)
        #expect(diff.nextCursor == "c2" && diff.omittedFileStats?.first?.path == "big.lock")
        let viewed = try Self.value(#"{"files":[{"path":"a.ts","state":"viewed"},{"path":"b.ts","state":"dismissed"}],"truncated":false}"#)
            .decode(as: PullRequestFilesViewedResult.self)
        #expect(viewed.files.map(\.state) == ["viewed", "dismissed"])
        let linked = try Self.value(#"{"threads":[{"id":"t1","projectId":"p1","title":"Fix","archivedAt":null}]}"#)
            .decode(as: PullRequestLinkedThreadsResult.self)
        #expect(linked.threads.first?.title == "Fix")
        let preview = try Self.value(#"{"projectId":"p1","repository":"o/r","number":3,"title":"T","url":"https://github.com/o/r/pull/3","author":null,"state":"open","isDraft":true,"createdAt":"2026-01-01T00:00:00Z"}"#)
            .decode(as: PullRequestPreview.self)
        #expect(preview.isDraft)
        let stack = try Self.value(#"{"id":"s1","number":1,"url":"u","base":"main","layers":[{"number":1,"headBranch":"a","state":"merged"},{"number":2,"title":"Two","isDraft":false,"headSha":"abc","headBranch":"b","state":"open"}]}"#)
            .decode(as: PullRequestStackDetail.self)
        #expect(stack.layers.count == 2 && stack.layers[1].title == "Two")
        let stats = try Self.value(#"{"stats":[{"projectId":"p1","repository":"o/r","number":3,"additions":5,"deletions":1}]}"#)
            .decode(as: PullRequestListStatsResult.self)
        #expect(stats.stats.first?.additions == 5)
        let reviewers = try Self.value(#"{"candidates":[{"login":"core","name":null,"avatarUrl":null,"id":"core","kind":"team","isRequested":true}],"truncated":false}"#)
            .decode(as: PullRequestReviewerCandidateList.self)
        #expect(reviewers.candidates.first?.kind == "team")
        let labels = try Self.value(#"{"candidates":[{"name":"bug","color":"d73a4a","description":null,"isApplied":false}],"truncated":true}"#)
            .decode(as: PullRequestLabelCandidateList.self)
        #expect(labels.truncated)
    }

    @Test func buildsPayloads() {
        let ref = PullRequestRef(projectId: "p1", host: "github.com", repository: "o/r", number: 7)
        let list = PullRequestPayloads.list(state: "open", involvement: "all", projectId: "p1",
                                            filters: PullRequestListFilters(draft: "hide", labels: [["bug"]]), query: "fix")
        #expect(list == .object(["state": .string("open"), "involvement": .string("all"), "limit": .number(99), "projectId": .string("p1"),
                                 "filters": .object(["draft": .string("hide"), "labels": .array([.array([.string("bug")])])]),
                                 "query": .string("fix")]))
        #expect(PullRequestPayloads.list(state: "all", involvement: "authored")["filters"] == nil)
        #expect(PullRequestPayloads.diff(ref, commit: "abc")["commit"] == .string("abc"))
        #expect(PullRequestPayloads.diff(ref)["host"] == .string("github.com"))
        #expect(PullRequestPayloads.action(ref, action: "merge", mergeMethod: "squash")["mergeMethod"] == .string("squash"))
        #expect(PullRequestPayloads.comment(ref, body: "   ") == nil)
        #expect(PullRequestPayloads.update(ref, title: "  ") == nil)
        #expect(PullRequestPayloads.update(ref, title: " New ")?["title"] == .string("New"))
        #expect(PullRequestPayloads.submitReview(ref, verdict: "approve", body: "")["comments"] == .array([]))
        let viewed = PullRequestPayloads.setFilesViewed(ref, files: [("a", true)])
        #expect(viewed["files"] == .array([.object(["path": .string("a"), "viewed": .bool(true)])]))
        let key = ThreadPullRequestKey(host: "GitHub.com", repository: "O/R", number: 7).normalized
        let link = PullRequestPayloads.link(threadId: "t1", key: key, url: "https://github.com/O/R/pull/7", commandId: "c1")
        #expect(link == .object(["type": .string("thread.pull-request.link"), "commandId": .string("c1"), "threadId": .string("t1"),
                                 "host": .string("github.com"), "repository": .string("o/r"), "number": .number(7),
                                 "url": .string("https://github.com/O/R/pull/7"), "source": .string("manual")]))
        #expect(PullRequestPayloads.unlink(threadId: "t1", key: key, commandId: "c2")["type"] == .string("thread.pull-request.unlink"))
        #expect(PullRequestPayloads.legacyLink(threadId: "t1", projectId: nil, repository: "o/r", number: 7, url: "u")["linkedPullRequest"] == .null)
    }

    @Test func errorMessages() {
        #expect(PullRequestErrors.message(tag: "PullRequestUnavailableError", fields: ["reason": .string("provider-unsupported")])
                == "Change requests cannot be browsed for this project's host yet.")
        #expect(PullRequestErrors.message(tag: "PullRequestUnavailableError", fields: ["reason": .string("cli-missing"), "provider": .string("github")])?
            .hasPrefix("No GitHub credential on the server.") == true)
        #expect(PullRequestErrors.message(tag: "PullRequestOperationError", fields: ["operation": .string("detail"), "detail": .string("boom")])
                == "Pull request operation detail failed: boom")
        #expect(PullRequestErrors.isNotFound(tag: "PullRequestOperationError", fields: ["reason": .string("not-found")]))
        #expect(PullRequestErrors.message(tag: "Other", fields: [:]) == nil)
    }

    @Test func parsesChangeRequestURLs() {
        #expect(ChangeRequestURL.parse("https://github.com/Owner/Repo/pull/12/files")?.key == ThreadPullRequestKey(host: "github.com", repository: "owner/repo", number: 12))
        #expect(ChangeRequestURL.parse("https://gitlab.example.com/g/sub/repo/-/merge_requests/4")?.repository == "g/sub/repo")
        #expect(ChangeRequestURL.parse("https://bitbucket.org/ws/repo/pull-requests/9")?.number == 9)
        #expect(ChangeRequestURL.parse("https://dev.azure.com/org/proj/_git/repo/pullrequest/5")?.repository == "org/proj/_git/repo")
        #expect(ChangeRequestURL.parse("https://codeberg.org:8443/a/b/pulls/2")?.authority == "codeberg.org:8443")
        #expect(ChangeRequestURL.parse("https://github.com/o/r/issues/12") == nil)
        #expect(ChangeRequestURL.parse("javascript:alert(1)") == nil)
        #expect(ChangeRequestURL.reference("#42") == "42")
        #expect(ChangeRequestURL.reference("az repos pr checkout --id 17") == "17")
        #expect(ChangeRequestURL.reference("https://github.com/o/r/pull/3") == "https://github.com/o/r/pull/3")
        #expect(ChangeRequestURL.reference("hello") == nil)
        #expect(ChangeRequestURL.url(kind: "gitlab", host: "gitlab.com", repository: "g/r", number: 1) == "https://gitlab.com/g/r/-/merge_requests/1")
        #expect(ChangeRequestURL.canonicalRepositoryKey("org.visualstudio.com/proj/_git/repo") == "dev.azure.com/org/proj/_git/repo")
    }

    static func link(_ number: Int, state: PullRequestState? = .open, draft: Bool = false, head: String? = nil, base: String = "main",
                     source: PullRequestLinkSource = .manual, linkedAt: String = "2026-09-01T00:00:00Z", updatedAt: String? = nil) -> ThreadPullRequestLink {
        let snapshot = state.map { s in
            PullRequestSnapshot(state: s, title: "PR \(number)", headBranch: head ?? "b\(number)", baseBranch: base, isDraft: draft,
                                updatedAt: updatedAt.map { T3Timestamp($0) }, syncedAt: "2026-09-01T00:00:00Z", closedAt: nil, mergedAt: nil, author: nil,
                                additions: nil, deletions: nil, changedFiles: nil, reviewDecision: nil, checksState: nil, mergeability: nil)
        }
        return ThreadPullRequestLink(host: "github.com", repository: "o/r", number: number, url: "https://github.com/o/r/pull/\(number)",
                                     source: source, linkedAt: T3Timestamp(linkedAt), snapshot: snapshot, stack: nil, watch: nil)
    }

    @Test func siblingPullRequestsStayUnderTheirParent() {
        let base = Self.link(1, head: "base"), left = Self.link(2, head: "left", base: "base"), right = Self.link(3, head: "right", base: "base")
        let grandchild = Self.link(4, head: "child", base: "left")
        let chain = ThreadPullRequests.chains([base, left, grandchild, right])
        #expect(chain.count == 1)
        #expect(chain.first?.depths == [0, 1, 2, 1])
        #expect(ThreadPullRequests.current([base, left, grandchild, right])?.number == 4)
    }

    @Test func threadLinkViews() {
        // Chained by base and head: 1 <- 2 <- 3 is one stack, 9 stands alone.
        let one = Self.link(1, head: "a"), two = Self.link(2, head: "b", base: "a"), three = Self.link(3, head: "c", base: "b")
        let lone = Self.link(9, state: .merged, head: "z")
        let chains = ThreadPullRequests.chains([three, lone, one, two])
        #expect(chains.map { $0.layers.map(\.number) } == [[9], [1, 2, 3]])
        #expect(ThreadPullRequests.current([three, lone, one, two])?.number == 3)
        #expect(ThreadPullRequests.badge([one, two, three]) == .init(kind: .stack(layers: 3), state: "open"))
        #expect(ThreadPullRequests.badge([lone]) == .init(kind: .pullRequest(others: 0), state: "merged"))
        #expect(ThreadPullRequests.badge([Self.link(4, draft: true)])?.state == "draft")
        #expect(ThreadPullRequests.badge([]) == nil)
        let dismissed = Self.link(5, source: .stackDismissed)
        #expect(ThreadPullRequests.visible([dismissed, lone]).map(\.number) == [9])
        let lines = ThreadPullRequests.lines([one, two, three])
        #expect(lines.map(\.depth) == [0, 1, 2])
        #expect(lines.first?.stackSize == 3)
        // One open link wins over newer finished ones.
        #expect(ThreadPullRequests.current([Self.link(7, state: .closed, updatedAt: "2026-10-01T00:00:00Z"), Self.link(8)])?.number == 8)
        // An unsynced link counts as open.
        #expect(ThreadPullRequests.current([Self.link(6, state: nil)])?.number == 6)
    }
}
