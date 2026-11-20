import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// The Issues page's list rules against fixtures/issues (4928 client-runtime issueList.ts,
/// state/issues.ts, issuePresentation.ts; T3's own cases in issueList.test.ts).
@MainActor
struct IssueListLogicTests {
    static var root: URL { SidebarFidelityTests.repo.appendingPathComponent("fixtures/issues") }
    static func list() throws -> IssueListResult {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("list.json"))).decode(as: IssueListResult.self)
    }
    static func detail() throws -> IssueDetail {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("detail.json"))).decode(as: IssueDetail.self)
    }

    @Test func groupsPerTrackerAndSorts() throws {
        let page = IssueListLogic.HeldPage(answer: try Self.list())
        let groups = IssueListLogic.group([("env", page)], query: "", sort: "updated") { _, project in project == "other" ? "github github.com" : nil }
        #expect(groups.map(\.key) == ["github github.com", "linear linear.app"])
        #expect(groups[0].rows.map(\.entry.displayKey) == ["#42", "#38", "#40"])
        #expect(groups[0].more == ["env"])
        #expect(groups[0].errors.first?.projectTitle == "other-repo")
        #expect(groups[1].rows.isEmpty && !groups[1].tracker.configured)
        let byCreated = IssueListLogic.group([("env", page)], query: "", sort: "created")
        #expect(byCreated[0].rows.map(\.entry.displayKey) == ["#42", "#40", "#38"])
    }

    @Test func sameIssueFromTwoEnvironmentsListsOnce() throws {
        // #38205: environments holding the same repository answer the same issue.
        let page = IssueListLogic.HeldPage(answer: try Self.list())
        let groups = IssueListLogic.group([("a", page), ("b", page)], query: "", sort: "updated")
        #expect(groups[0].rows.count == 3 && groups[0].rows.allSatisfy { $0.environmentId == "a" })
        #expect(groups[0].more == ["a", "b"])
    }

    @Test func narrowsLocallyWhenTheTrackerCannotSearch() throws {
        var answer = try Self.list()
        answer.trackers[0].capabilities?.search = false
        let groups = IssueListLogic.group([("env", .init(answer: answer))], query: "palette", sort: "updated")
        #expect(groups[0].rows.map(\.entry.displayKey) == ["#38"])
        answer.trackers[0].capabilities?.search = true
        #expect(IssueListLogic.group([("env", .init(answer: answer))], query: "palette", sort: "updated")[0].rows.count == 3)
    }

    @Test func continuationMergesAndKeepsRowsOnFailure() throws {
        let first = IssueListLogic.HeldPage(answer: try Self.list())
        let asked = IssueListLogic.cursors(first.nextCursors, host: "github.com")
        #expect(asked == ["github.com acme/demo-repo": "Y3Vyc29yOjM="])
        var older = first.answer.entries[1]
        older.key = "12"; older.displayKey = "#12"; older.url += "-12"; older.updatedAt = "2026-10-01T00:00:00.000Z"
        var renamed = first.answer.entries[0]
        renamed.title = "Renamed"
        let next = IssueListResult(entries: [older, renamed], errors: [], nextCursors: [:])
        let held = IssueListLogic.continuePage(first, .page(next), asked: asked)
        #expect(held.entries.count == 4 && held.entries.first?.title == "Renamed")
        #expect(held.nextCursors.isEmpty && held.moreFailure == nil)
        let failed = IssueListLogic.continuePage(first, .failure("The next page failed."), asked: asked)
        #expect(failed.entries == first.entries && failed.moreFailure == "The next page failed.")
    }

    @Test func hostOptionsKeepARememberedHost() throws {
        let trackers = try Self.list().trackers
        let options = IssueListLogic.hostOptions(trackers, chosen: "gitlab.example.com")
        #expect(options.map(\.value) == ["", "gitlab.example.com", "github.com", "linear.app"])
        #expect(options[2].label == "GitHub (github.com)")
        #expect(options[3].unavailable == "This tracker has no working credentials.")
    }

    @Test func statePresentationAndEvents() throws {
        #expect(IssueListLogic.tone(IssueState(category: "open", name: "In Review")) == .open)
        #expect(IssueListLogic.tone(IssueState(category: "closed", name: "Closed", closeReason: "completed")) == .completed)
        #expect(IssueListLogic.tone(IssueState(category: "closed", name: "Done")) == .completed)
        #expect(IssueListLogic.tone(IssueState(category: "closed", name: "Not planned", closeReason: "not_planned")) == .notPlanned)
        let closed = IssueEvent(id: "1", kind: "closed", actor: nil, createdAt: "", detail: "not_planned")
        #expect(IssueListLogic.eventSentence(closed) == "closed this as not planned")
        #expect(IssueListLogic.eventSentence(IssueEvent(id: "2", kind: "labeled", actor: nil, createdAt: "", detail: nil)) == "added a label")
    }

    @Test func writeAccess() throws {
        var d = try Self.detail()
        var a = IssueListLogic.access(d, canWrite: true)
        #expect(a.blocked == nil && a.comment && a.edit && a.labels && a.react)
        #expect(a.states.map(\.name) == ["Closed", "Closed as not planned"])
        d.writable = false
        a = IssueListLogic.access(d, canWrite: true)
        #expect(a.blocked?.contains("read-only") == true && !a.comment && a.states.isEmpty)
        d.writable = true
        d.viewerPermissions.setState = false
        #expect(IssueListLogic.access(d, canWrite: true).states.isEmpty)
        #expect(IssueListLogic.access(d, canWrite: false).blocked?.contains("write scope") == true)
    }

    @Test func timelineAndOlderComments() throws {
        let d = try Self.detail()
        let items = IssueListLogic.timeline(comments: d.comments, events: d.events)
        let ids: [String] = items.map { if case .comment(let c) = $0 { return c.id } else if case .event(let e) = $0 { return e.id }; return "" }
        #expect(ids == ["e1", "e2", "c2", "c3"])
        let older = [IssueComment(id: "c1", author: nil, body: "first", createdAt: "2026-11-10T10:00:00.000Z"), d.comments[0]]
        #expect(IssueListLogic.prepend(d.comments, older: older).map(\.id) == ["c1", "c2", "c3"])
    }

    @Test func surfaceIdAndTitle() {
        let t = IssueSurfaceTarget(environmentId: "env", projectId: "demo", tracker: "github", host: "GitHub.com", scope: "Acme/Demo", key: "42")
        #expect(t.surfaceId == "issue:env:demo:github:github.com:acme%2Fdemo:42")
        #expect(RightPanelSurface.issue(t).title == "#42")
        let linear = IssueSurfaceTarget(projectId: "demo", tracker: "linear", host: nil, scope: "ENG", key: "ENG-7")
        #expect(RightPanelSurface.issue(linear).title == "ENG-7")
    }

    @Test func savedViewsMatchAndName() {
        let view = SavedView(id: "1", name: "Mine", preferences: ["who": .string("assigned"), "status": .string("open"),
                                                                 "label": .array([.string("b"), .string("a")])])
        #expect(SavedViews.matches(view, ["who": .string("assigned"), "status": .string("open"), "label": .array([.string("a"), .string("b")]), "q": .string("")]))
        #expect(!SavedViews.matches(view, ["who": .string("all"), "status": .string("open")]))
        #expect(SavedViews.nameError(" ", views: [view], editingId: nil) == "Enter a name for this view.")
        #expect(SavedViews.nameError("mine", views: [view], editingId: nil) == "A view with this name already exists.")
        #expect(SavedViews.nameError("mine", views: [view], editingId: "1") == nil)
        #expect(SavedViewsKind.issues.suggestedName(["who": .string("assigned")]) == "Issues Assigned to Me")
    }
}
