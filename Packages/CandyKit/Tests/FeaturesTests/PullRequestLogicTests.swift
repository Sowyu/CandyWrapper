import Foundation
import Testing
@testable import T3Protocol
@testable import Features
import T3Store

struct PullRequestSurfaceTests {
    @Test func opensPullRequestTabs() {
        let target = PullRequestSurfaceTarget(environmentId: "env 1", projectId: "p:1", host: "GitHub.com", repository: "o/r", number: 7)
        // `pullRequestSurfaceId`: URI encoded parts, the host lower case.
        #expect(target.surfaceId == "pull-request:env%201:p%3A1:github.com:o%2Fr:7")
        var state = RightPanelState()
        state.openPullRequest(target)
        state.open(.diff)
        var newer = target
        newer.url = "https://github.com/o/r/pull/7"
        state.openPullRequest(newer)
        #expect(state.surfaces.count == 2)
        #expect(state.active?.pullRequest?.url == newer.url)
        #expect(state.active?.title == "#7")
        state.open(.pullRequests)
        #expect(state.active?.title == "Pull requests")
        // Dropping file tabs keeps the pull request ones.
        state.dropFileSurfaces()
        #expect(state.surfaces.count == 3)
    }
}

/// Ports of T3's pull request logic tests (pullRequestList.logic.test.ts, pullRequestDetail.logic.test.ts,
/// pullRequestFilesViewed.logic.test.ts, LinkPullRequestDialog.logic.test.ts).
struct PullRequestListLogicTests {
    typealias L = PullRequestListLogic

    static func entry(_ number: Int, title: String = "Add the pull requests page", author: String = "octocat", state: String = "open",
                      isDraft: Bool = false, mergeability: String = "mergeable", additions: Int = 1, deletions: Int = 0,
                      updatedAt: String = "2026-07-02T00:00:00Z", createdAt: String = "2026-07-01T00:00:00Z", reviewRequested: Bool = false,
                      labels: [String] = [], reviewDecision: String? = nil, checksState: String? = nil) -> PullRequestListEntry {
        PullRequestListEntry(projectId: "project-1", projectTitle: "t3code", repository: "pingdotgg/t3code", number: number, title: title,
                             author: PullRequestActor(login: author), headBranch: "feat/branch-\(number)", state: state, isDraft: isDraft,
                             mergeability: mergeability, additions: additions, deletions: deletions, createdAt: createdAt, updatedAt: updatedAt,
                             viewerReviewRequested: reviewRequested, labels: labels.map { PullRequestLabel(name: $0) },
                             reviewDecision: reviewDecision, checksState: checksState, environmentId: "env-1")
    }

    @Test func parsesQualifiers() {
        #expect(L.parseQuery("label:bug label:a,b").filters.labels == [["bug"], ["a", "b"]])
        let scalars = L.parseQuery("author:octocat DRAFT:false review:changes_requested status:failure").filters
        #expect(scalars == PullRequestListFilters(draft: "hide", review: "changes-requested", checks: "failing", author: "octocat"))
        let unknown = L.parseQuery("milestone:v2 draft:maybe status: parser")
        #expect(unknown.filters == PullRequestListFilters(labels: [["milestone:v2"]]))
        #expect(unknown.text == "draft:maybe status: parser")
        #expect(L.parseQuery("label:\"needs,triage\"").filters.labels == [["needs,triage"]])
        #expect(L.parseQuery("-label:\"needs,triage\"").filters.excludedLabels == ["needs,triage"])
        #expect(L.parseQuery("   ").text.isEmpty && L.parseQuery("   ").filters.isEmpty)
    }

    /// pullRequestQuery.test.ts (9f70fcc7b5): commas split outside quotes, and the Draft menu replaces a typed `draft:`.
    @Test func quotedCommasAndTypedDraft() {
        #expect(L.parseQuery("label:\"needs,triage\",wip").filters.labels == [["needs,triage", "wip"]])
        #expect(L.parseQuery("label:\"needs design\",,wip").filters.labels == [["needs design", "wip"]])
        typealias F = PullRequestListFilters
        let replaced = L.applyDraftFilterChange(query: "draft:false fix label:\"needs design\"", menu: F(), next: F(draft: "only"))
        #expect(replaced.query == "fix label:\"needs design\"" && replaced.filters == F(draft: "only"))
        let cleared = L.applyDraftFilterChange(query: "draft:true \"draft:false\" fix", menu: F(draft: "only"), next: F())
        #expect(cleared.query == "\"draft:false\" fix" && cleared.filters == F())
        // Another filter changing keeps the typed query and the stored menu draft.
        let other = L.applyDraftFilterChange(query: "draft:false fix", menu: F(draft: "only"), next: F(draft: "hide", checks: "passing"))
        #expect(other.query == "draft:false fix" && other.filters == F(draft: "only", checks: "passing"))
        let untyped = L.applyDraftFilterChange(query: "fix", menu: F(), next: F(draft: "hide"))
        #expect(untyped.query == "fix" && untyped.filters == F(draft: "hide"))
        #expect(L.shownMenuFilters(query: "draft:true fix", menu: F(draft: "hide", review: "none")) == F(draft: "only", review: "none"))
        #expect(L.shownMenuFilters(query: "fix", menu: F(draft: "hide")) == F(draft: "hide"))
    }

    @Test func boundsTypedQualifiers() {
        let many = (0..<14).map { "l\($0)" }.joined(separator: ",")
        let long = String(repeating: "x", count: 240)
        let parsed = L.parseQuery("label:\(many) label:\(long) author:\(long)")
        #expect(parsed.filters.labels?[0].count == 10)
        #expect(parsed.filters.labels?[1] == [String(repeating: "x", count: 200)])
        #expect(parsed.filters.author == String(repeating: "x", count: 200))
        #expect(L.parseQuery("size:\(long)").filters.labels == [[String("size:\(long)".prefix(200))]])
    }

    @Test func namespacedLabels() {
        #expect(L.parseQuery("size:XXL").filters.labels == [["size:XXL"]])
        #expect(L.parseQuery("size:XXL").text == "")
        #expect(L.parseQuery("size:S,XS").filters.labels == [["size:S", "size:XS"]])
        #expect(L.parseQuery("size:S,size:XS").filters.labels == [["size:S", "size:XS"]])
        #expect(L.parseQuery("-size:S,XS").filters.excludedLabels == ["size:S", "size:XS"])
        #expect(L.parseQuery("\"size:XXL\"").filters.labels == nil)
        #expect(L.parseQuery("\"size:XXL\"").text == "\"size:XXL\"")
        #expect(L.parseQuery("priority-1:high").filters.labels == [["priority-1:high"]])
        // A pasted link is text, not a label named after its scheme.
        #expect(L.parseQuery("https://github.com/a/b").filters.labels == nil)
    }

    @Test func filtersRows() {
        let bug = Self.entry(1, labels: ["bug", "size:S"])
        let docs = Self.entry(2, isDraft: true, labels: ["docs"], reviewDecision: "approved")
        #expect(L.matchesFilters(bug, PullRequestListFilters(labels: [["bug", "docs"]])))
        #expect(!L.matchesFilters(bug, PullRequestListFilters(labels: [["bug"], ["docs"]])))
        #expect(!L.matchesFilters(bug, PullRequestListFilters(excludedLabels: ["BUG"])))
        #expect(L.matchesFilters(docs, PullRequestListFilters(draft: "only", review: "approved")))
        #expect(!L.matchesFilters(docs, PullRequestListFilters(review: "none")))
        #expect(L.matchesFilters(bug, PullRequestListFilters(review: "none")))
        #expect(L.matchesFilters(bug, PullRequestListFilters(author: "@me"), viewer: "octocat"))
        #expect(!L.matchesFilters(bug, PullRequestListFilters(author: "me"), viewer: "someone"))
    }

    @Test func groupsByInvolvement() {
        let viewers = ["env-1 github.com": "octocat"]
        let mine = Self.entry(1)
        let asked = Self.entry(2, author: "hubot", reviewRequested: true)
        let other = Self.entry(3, author: "hubot")
        let groups = L.groupByInvolvement([other, asked, mine], viewers: viewers)
        #expect(groups.map(\.key) == [.authored, .reviewRequested, .others])
        #expect(groups.map(\.label) == ["Authored", "Review requested", "Others"])
        #expect(L.groupByInvolvement([other], viewers: viewers).map(\.key) == [.others])
        #expect(L.filterByInvolvement([other, asked, mine], viewers: viewers, involvement: "authored").map(\.number) == [1])
        #expect(L.filterByInvolvement([other, asked, mine], viewers: viewers, involvement: "reviewing").map(\.number) == [2])
    }

    @Test func partitionsWithPriorityReads() {
        let a1 = Self.entry(1, updatedAt: "2026-07-01T00:00:00Z")
        let a2 = Self.entry(2, updatedAt: "2026-07-03T00:00:00Z")
        let both = Self.entry(3, updatedAt: "2026-07-02T00:00:00Z")
        var fresh = a1; fresh.title = "Fresher copy"
        let groups = L.partition([Self.entry(9), fresh], authored: [a1, a2, both], reviewRequested: [both, Self.entry(4)])
        #expect(groups.map(\.key) == [.authored, .reviewRequested, .others])
        #expect(groups[0].entries.map(\.number) == [2, 3, 1])
        #expect(groups[0].entries.last?.title == "Fresher copy")
        #expect(groups[1].entries.map(\.number) == [4])
        #expect(groups[2].entries.map(\.number) == [9])
    }

    @Test func scoresAndRanksSearches() {
        let titled = Self.entry(1, title: "Add the welcome wizard", updatedAt: "2026-07-01T00:00:00Z")
        let mentioned = Self.entry(2, title: "Unrelated work", updatedAt: "2026-08-01T00:00:00Z")
        #expect(L.rank([mentioned, titled], "welcome wizard").map(\.number) == [1, 2])
        #expect(L.score(Self.entry(1, title: "The wizard that welcomes"), "welcome wizard") == 70)
        #expect(L.score(Self.entry(1, title: "A wizard, of sorts"), "welcome wizard") == 30)
        #expect(L.score(Self.entry(42), "#42") == 100)
        #expect(L.score(Self.entry(42), "43") == 0)
        let older = Self.entry(1, title: "no match here", updatedAt: "2026-07-01T00:00:00Z")
        let newer = Self.entry(2, title: "none here either", updatedAt: "2026-08-01T00:00:00Z")
        #expect(L.rank([older, newer], "wizard").map(\.number) == [2, 1])
        #expect(L.rank([older, newer], "  ").map(\.number) == [1, 2])
        #expect(L.matchesQuery(Self.entry(7), "#7"))
        #expect(L.matchesQuery(Self.entry(7), "feat/branch"))
    }

    @Test func ranksByMergeReadiness() {
        let conflict = Self.entry(1, mergeability: "conflicting", updatedAt: "2026-09-01T00:00:00Z", reviewDecision: "approved", checksState: "passing")
        let other = Self.entry(2, updatedAt: "2026-08-01T00:00:00Z", checksState: "pending")
        let green = Self.entry(3, updatedAt: "2026-07-01T00:00:00Z", reviewDecision: "review-required", checksState: "passing")
        let approved = Self.entry(4, additions: 1000, updatedAt: "2026-06-01T00:00:00Z", reviewDecision: "approved", checksState: "passing")
        let draft = Self.entry(5, isDraft: true, updatedAt: "2026-09-02T00:00:00Z", reviewDecision: "approved", checksState: "passing")
        let finished = Self.entry(6, state: "merged", updatedAt: "2026-09-03T00:00:00Z", reviewDecision: "approved", checksState: "passing")
        #expect(L.rankByMergeReadiness([conflict, other, green, approved, draft, finished]).map(\.number) == [4, 3, 5, 2, 6, 1])
    }

    @Test func ranksBlockedOnMe() {
        let rows = [Self.entry(6), Self.entry(7, state: "merged", updatedAt: "2026-08-01T00:00:00Z"),
                    Self.entry(2, updatedAt: "2026-08-01T00:00:00Z", checksState: "failing"),
                    Self.entry(5, isDraft: true, checksState: "passing"),
                    Self.entry(4, reviewDecision: "approved", checksState: "passing"),
                    Self.entry(3, updatedAt: "2026-08-02T00:00:00Z", reviewDecision: "changes-requested", checksState: "failing"),
                    Self.entry(8, state: "closed", updatedAt: "2026-08-03T00:00:00Z"),
                    Self.entry(1, mergeability: "conflicting", updatedAt: "2026-08-01T00:00:00Z", checksState: "failing"),
                    Self.entry(9, updatedAt: "2026-08-03T00:00:00Z", checksState: "failing")]
        #expect(L.rankBlockedOnAuthor(rows).map(\.number) == [1, 3, 9, 2, 5, 6, 4, 8, 7])
        let reviewer = [Self.entry(4, state: "closed", updatedAt: "2026-08-03T00:00:00Z"), Self.entry(2, updatedAt: "2026-08-02T00:00:00Z"),
                        Self.entry(3, state: "merged", updatedAt: "2026-08-01T00:00:00Z"), Self.entry(1, updatedAt: "2026-08-01T00:00:00Z")]
        #expect(L.rankBlockedOnReviewer(reviewer).map(\.number) == [2, 1, 4, 3])
    }

    @Test func sortsGroups() {
        let small = Self.entry(1, additions: 2, createdAt: "2026-07-01T00:00:00Z")
        let big = Self.entry(2, additions: 50, createdAt: "2026-07-05T00:00:00Z")
        let unknown = Self.entry(3, additions: 0, createdAt: "2026-07-03T00:00:00Z")
        let g = [L.Group(key: .others, label: "Others", entries: [small, big, unknown])]
        #expect(L.sortGroups(g, sort: "largest", searchText: "")[0].entries.map(\.number) == [2, 1, 3])
        #expect(L.sortGroups(g, sort: "smallest", searchText: "")[0].entries.map(\.number) == [1, 2, 3])
        #expect(L.sortGroups(g, sort: "newest", searchText: "")[0].entries.map(\.number) == [2, 3, 1])
        #expect(L.sortGroups(g, sort: "oldest", searchText: "")[0].entries.map(\.number) == [1, 3, 2])
        #expect(L.sortGroups(g, sort: "updated", searchText: "")[0].entries.map(\.number) == [1, 2, 3])
        // A search keeps its relevance order under the default sort.
        #expect(L.sortGroups(g, sort: "ready", searchText: "x")[0].entries.map(\.number) == [1, 2, 3])
    }

    @Test func overridesAndSettlement() {
        let row = Self.entry(1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let close = L.override(after: "close", entry: row, now: now, token: 1)!
        #expect(close.state == "closed")
        #expect(L.override(after: "update-branch", entry: row, now: now, token: 2) == nil)
        #expect(L.override(after: "draft", entry: row, now: now, token: 3)?.isDraft == true)
        let key = L.key(row)
        #expect(L.apply([key: close], to: [row], state: "open").isEmpty)
        #expect(L.apply([key: close], to: [row], state: "all").first?.state == "closed")
        // Kept until an answer agrees, and for a minute against one that does not.
        #expect(L.settle([key: close], answered: [row], now: close.at + 1000).count == 1)
        #expect(L.settle([key: close], answered: [row], now: close.at + 61_000).isEmpty)
        var closed = row; closed.state = "closed"
        #expect(L.settle([key: close], answered: [closed], now: close.at + 1000).isEmpty)
        #expect(L.settle([key: close], answered: [], now: close.at + 120_000).count == 1)
    }

    @Test func facetsAndLabels() {
        let rows = [Self.entry(1, author: "b", state: "merged", labels: ["x"]), Self.entry(2, author: "a", labels: ["x", "y"]),
                    Self.entry(3, author: "a", labels: ["y"]), Self.entry(4, author: "c", state: "merged")]
        let f = L.facets(rows, state: "open")
        #expect(f.authors.map(\.actor.login) == ["a"])
        #expect(f.labels.map(\.name) == ["y", "x"])
        let all = L.facets(rows, state: "all")
        #expect(all.authors.map(\.actor.login) == ["b", "c", "a"])
        #expect(L.labelColor("#0E8A16") == "#0E8A16")
        #expect(L.labelColor("0e8a16") == "#0e8a16")
        #expect(L.labelColor("red") == nil)
        #expect(L.hostLabel([("github.com", "github"), ("ghe.corp", "github")], ("ghe.corp", "github")) == "ghe.corp")
        #expect(L.hostLabel([("github.com", "github"), ("gitlab.com", "gitlab")], ("gitlab.com", "gitlab")) == "GitLab")
    }
}

struct PullRequestDetailLogicTests {
    typealias D = PullRequestDetailLogic

    static func check(_ status: String, url: String? = nil) -> PullRequestCheck { PullRequestCheck(name: status, status: status, url: url) }

    @Test func summarizesChecks() {
        #expect(D.summarizeChecks([]) == "No checks reported")
        #expect(D.summarizeChecks([Self.check("success"), Self.check("failure")]) == "1 of 2 failing")
        #expect(D.summarizeChecks([Self.check("success"), Self.check("pending")]) == "1 of 2 running")
        #expect(D.summarizeChecks([Self.check("success"), Self.check("success")]) == "All checks passed")
        #expect(D.summarizeChecks([Self.check("success"), Self.check("skipped")]) == "1 of 2 passing")
        #expect(D.summarizeChecks([Self.check("action-required", url: "https://github.com/o/r/actions/runs/12")]) == "1 workflow awaiting approval")
        #expect(D.summarizeChecks([Self.check("action-required")]) == "1 check awaiting action")
        #expect(D.describeChecks([Self.check("pending"), Self.check("failure"), Self.check("success")]) == "1 of 3 running · 1 failed")
        #expect(D.checksState([Self.check("success"), Self.check("cancelled")]) == "failing")
        #expect(D.checksState([Self.check("success"), Self.check("action-required")]) == "pending")
        #expect(D.checksState([Self.check("skipped")]) == nil)
        #expect(D.checkStatusLabel(Self.check("action-required", url: "https://github.com/o/r/actions/runs/1/job")) == "Awaiting approval")
    }

    @Test func primaryControl() {
        func p(_ state: String = "open", draft: Bool = false, merge: String = "mergeable", checks: String? = "passing", auto: Bool? = nil,
               method: Bool = true, canMerge: Bool = true, ready: Bool = true, canAuto: Bool = true) -> String? {
            D.primaryControl(state: state, isDraft: draft, mergeability: merge, checksState: checks, autoMergeEnabled: auto,
                             hasMergeMethod: method, canMerge: canMerge, canMarkReady: ready, canEnableAutoMerge: canAuto)
        }
        #expect(p("merged") == "merged")
        #expect(p("closed") == "closed")
        #expect(p(merge: "conflicting") == "resolve")
        #expect(p(draft: true) == "ready")
        #expect(p(draft: true, ready: false) == nil)
        #expect(p(auto: true) == "auto-merge-armed")
        #expect(p(checks: "pending", auto: false) == "enable-auto-merge")
        #expect(p(checks: "pending", auto: nil) == "merge")
        #expect(p(method: false) == nil)
        #expect(p(canMerge: false) == nil)
        #expect(D.mergeMethodLabel("squash") == "Squash and merge")
        #expect(D.selectedMergeMethod(["squash", "rebase"], preferred: "merge") == "squash")
        // The pick on this pull request, then the project's default merge method, then the last pick.
        #expect(D.selectedMergeMethod(["merge", "squash", "rebase"], projectDefault: "rebase", preferred: "squash") == "rebase")
        #expect(D.selectedMergeMethod(["merge", "squash", "rebase"], current: "merge", projectDefault: "rebase", preferred: "squash") == "merge")
        #expect(D.selectedMergeMethod(["merge", "squash"], projectDefault: "rebase", preferred: "squash") == "squash")
        #expect(D.checkoutCommand(provider: "github", number: 12) == "gh pr checkout 12")
        #expect(D.openOnHostLabel("github") == "Open on GitHub")
        // pullRequestDiffError.ts:1-14
        #expect(D.describeDiffError("RpcClientError: API rate limit exceeded", providerName: "GitHub").title == "GitHub rate limit reached")
        #expect(D.describeDiffError("HTTP 429 Too Many Requests", providerName: "GitLab").title == "GitLab rate limit reached")
        #expect(D.describeDiffError("exit code 128", providerName: "GitHub") == ("Couldn't load the changes",
            "The environment couldn't load this pull request's diff. Try again, or view the changes on GitHub."))
    }

    @Test func reviewOutcomes() {
        let comments = [
            PullRequestComment(id: "1", kind: "review", author: PullRequestActor(login: "a"), body: "", createdAt: "2026-07-01T00:00:00Z", reviewState: "APPROVED"),
            PullRequestComment(id: "2", kind: "review", author: PullRequestActor(login: "a"), body: "", createdAt: "2026-07-03T00:00:00Z", reviewState: "CHANGES_REQUESTED"),
            PullRequestComment(id: "3", kind: "review", author: PullRequestActor(login: "b"), body: "", createdAt: "2026-07-02T00:00:00Z", reviewState: "approved"),
            PullRequestComment(id: "4", kind: "review", author: PullRequestActor(login: "c"), body: "", createdAt: "2026-07-02T00:00:00Z", reviewState: "dismissed"),
            PullRequestComment(id: "5", kind: "review", author: nil, body: "", createdAt: "2026-07-02T00:00:00Z", reviewState: "approved"),
            PullRequestComment(id: "6", kind: "review", author: nil, body: "", createdAt: "2026-07-02T00:00:00Z", reviewState: "commented"),
        ]
        let commits = [PullRequestCommit(oid: "abc", messageHeadline: "x", committedDate: "2026-07-02T12:00:00Z")]
        let outcomes = D.latestReviewOutcomes(comments, commits: commits)
        #expect(outcomes.map(\.key) == ["a", "b", "ghost:5"])
        #expect(outcomes.map(\.outcome) == ["changes-requested", "approved", "approved"])
        #expect(outcomes.map(\.stale) == [false, true, true])
        #expect(D.reviewOutcome("Changes_Requested") == "changes-requested")
        #expect(D.reviewOutcome("COMMENTED") == nil)
    }

    @Test func timeline() throws {
        let d = try PullRequestFixtures.detail()
        let events = D.timeline(d)
        #expect(events.first?.kind == .merged)
        #expect(events.last?.kind == .opened)
        #expect(!events.contains { $0.kind == .closed })
        let rows = D.groupConversations(events)
        // Remarks without a verdict fold together; the approval is its own row.
        let conversations = rows.compactMap { if case .comments(let e) = $0 { e.count } else { nil } }
        #expect(conversations == [2])
        #expect(rows.contains { if case .event(let e) = $0 { e.reviewState == "APPROVED" } else { false } })
        #expect(D.visibleBody("<!-- bot -->\n  ") == nil)
        #expect(D.visibleBody("  hi <!-- x --> ") == "hi <!-- x -->")
    }

    @Test func viewedFiles() {
        let states = ["a": "viewed", "b": "dismissed", "c": "unviewed"]
        #expect(D.isFileViewed("a", states: states, overlay: [:]))
        #expect(!D.isFileViewed("b", states: states, overlay: [:]))
        #expect(D.isStale("b", states: states))
        #expect(D.isFileViewed("c", states: states, overlay: ["c": true]))
        #expect(D.countViewed(["a", "b", "c"], states: states, overlay: ["c": true]) == 2)
        // A press stays until a read that could have seen it agrees, or answers for it.
        #expect(D.settleOverlay(["c": true], states: states, pending: [], answered: []) == ["c": true])
        #expect(D.settleOverlay(["a": true], states: states, pending: [], answered: []).isEmpty)
        #expect(D.settleOverlay(["a": true], states: states, pending: ["a"], answered: []) == ["a": true])
        #expect(D.settleOverlay(["c": true], states: states, pending: [], answered: ["c"]).isEmpty)
        #expect(D.revertOverlay(["c": true, "a": false], batch: [("c", true), ("a", false)], owned: ["c"]) == ["a": false])
    }

    @Test func threadPanelAction() throws {
        var d = try PullRequestFixtures.detail()
        d.state = "open"; d.mergedAt = nil
        d.checks = [Self.check("failure")]
        #expect(D.threadPanelAction(d) == "fix")
        d.checks = [Self.check("pending")]
        #expect(D.threadPanelAction(d) == nil)
        d.checks = [Self.check("success")]
        #expect(D.threadPanelAction(d) == "merge")
        d.mergeability = "conflicting"
        #expect(D.threadPanelAction(d) == "resolve")
    }

    @Test func stackRows() {
        let stack = PullRequestStackDetail(id: "s", number: 1, url: "u", base: "main", layers: [
            .init(number: 10, title: "Bottom", isDraft: nil, headSha: nil, headBranch: "a", state: "merged"),
            .init(number: 11, title: "Middle", isDraft: true, headSha: nil, headBranch: "b", state: "open"),
            .init(number: 12, title: "Top", isDraft: nil, headSha: nil, headBranch: "c", state: "open"),
        ])
        let rows = D.stackRows(stack, current: 11)
        #expect(rows.map(\.number) == [12, 11, 10])
        #expect(rows.map(\.position) == [3, 2, 1])
        #expect(rows.map(\.isCurrent) == [false, true, false])
        #expect(PullRequestStateTone(state: "open", isDraft: true) == .draft)
        #expect(PullRequestStateTone(state: "merged", isDraft: true) == .merged)
    }
}

struct LinkPullRequestLogicTests {
    let project = LinkPullRequestLogic.Project(host: "github.com", repository: "pingdotgg/t3code", kind: "github")

    @Test func resolvesInputs() {
        #expect(LinkPullRequestLogic.resolve("#42", project: project) == .link(.init(host: "github.com", repository: "pingdotgg/t3code", number: 42,
                                                                                      url: "https://github.com/pingdotgg/t3code/pull/42")))
        #expect(LinkPullRequestLogic.resolve("gh pr checkout 7", project: project)
                == .link(.init(host: "github.com", repository: "pingdotgg/t3code", number: 7, url: "https://github.com/pingdotgg/t3code/pull/7")))
        #expect(LinkPullRequestLogic.resolve("https://github.com/Owner/Repo/pull/9", project: nil)
                == .link(.init(host: "github.com", repository: "owner/repo", number: 9, url: "https://github.com/Owner/Repo/pull/9")))
        #expect(LinkPullRequestLogic.resolve("12", project: nil) == .error("Paste the full pull request URL; this thread has no repository to resolve the number against."))
        #expect(LinkPullRequestLogic.resolve("https://github.com/o/r/pull/3", project: nil, canLink: { _ in false })
                == .error("No project in this environment can read github.com/o/r."))
        #expect(LinkPullRequestLogic.resolve("nonsense", project: project) == nil)
        #expect(LinkPullRequestLogic.resolve("#0", project: project) == nil)
        #expect(LinkPullRequestLogic.resolve("5", project: .init(host: "x", repository: "a/b", kind: "unknown"))
                == .error("Paste a full URL; this project's host has no known change request URL."))
    }

    @Test func validation() {
        #expect(LinkPullRequestLogic.validation("", dirty: false, outcome: nil) == nil)
        #expect(LinkPullRequestLogic.validation(" ", dirty: true, outcome: nil) == "Paste a pull request URL or enter 123 / #123.")
        #expect(LinkPullRequestLogic.validation("abc", dirty: true, outcome: nil) == "Use a pull request URL, 123, or #123.")
    }
}

/// The detail fixture from fixtures/pull-requests/detail.json (shapes from T3's own tests).
enum PullRequestFixtures {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/pull-requests") }

    static func json(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(name)))
    }

    static func detail() throws -> PullRequestDetail {
        var d = try json("detail.json").decode(as: PullRequestDetail.self)
        d.apply(try json("activity.json").decode(as: PullRequestActivity.self))
        return d
    }

    static func list() throws -> PullRequestListResult { try json("list.json").decode(as: PullRequestListResult.self) }
}

/// 2994: quick actions follow each host's reported `actions` (pullRequestList.logic.ts:1268-1306).
struct PullRequestQuickActionTests {
    @Test func followTheHost() throws {
        let summary = { (host: String, actions: [String]?) in
            var json: [String: JSONValue] = ["host": .string(host), "kind": .string("forgejo"), "searchesOnHost": .bool(true),
                                             "projectCount": .number(1), "configured": .bool(true), "detail": .null]
            if let actions { json["actions"] = .array(actions.map(JSONValue.string)) }
            return try JSONValue.object(json).decode(as: PullRequestProviderSummary.self)
        }
        let byHost = PullRequestListLogic.hostActions([try summary("Code.Example", ["close", "reopen"]), try summary("old.example", nil)])
        #expect(byHost == ["code.example": ["close", "reopen"]])
        let q = { (state: String, draft: Bool, host: String, provider: String) in
            PullRequestListLogic.quickActions(state: state, isDraft: draft, host: host, provider: provider, byHost: byHost)
        }
        #expect(q("open", false, "code.example", "forgejo") == ["close"])
        #expect(q("open", true, "CODE.example", "forgejo") == ["close"])
        #expect(q("closed", false, "code.example", "forgejo") == ["reopen"])
        #expect(q("merged", false, "code.example", "forgejo") == [])
        // A host the server says nothing about: GitHub keeps the old four, others get none.
        #expect(q("open", false, "github.com", "github") == ["close", "merge"])
        #expect(q("open", true, "github.com", "github") == ["close", "ready"])
        #expect(q("open", false, "old.example", "gitlab") == [])
    }
}
