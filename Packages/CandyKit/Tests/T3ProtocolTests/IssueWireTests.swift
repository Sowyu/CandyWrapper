import Foundation
import Testing
@testable import T3Protocol

/// Decoding of the 4928 issue payloads (fixtures/issues, hand-written after
/// packages/contracts/src/issue.ts, since the sandbox has no signed-in tracker), the payloads the
/// app sends, and the thread link commands (orchestrationV2.ts:3301-3318).
struct IssueWireTests {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/issues") }
    static func json(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(name)))
    }

    @Test func decodesList() throws {
        let list = try Self.json("list.json").decode(as: IssueListResult.self)
        #expect(list.entries.count == 3)
        #expect(list.entries[0].displayKey == "#42" && list.entries[0].assignees.count == 2)
        #expect(list.entries[1].author == nil && list.entries[1].state.closeReason == "completed")
        #expect(list.trackers[1].capabilities == nil && !list.trackers[1].configured)
        #expect(list.nextCursors["github.com acme/demo-repo"] == "Y3Vyc29yOjM=")
        #expect(list.scopes?.first?.scope == "acme/demo-repo")
        #expect(list.errors.first?.projectTitle == "other-repo")
    }

    @Test func listWithoutScopesDecodes() throws {
        // Servers before #38085 leave `scopes` out.
        let text = #"{"viewers":{},"trackers":[],"entries":[],"errors":[],"nextCursors":{}}"#
        let list = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).decode(as: IssueListResult.self)
        #expect(list.scopes == nil && list.entries.isEmpty)
    }

    @Test func decodesDetail() throws {
        let d = try Self.json("detail.json").decode(as: IssueDetail.self)
        #expect(d.states.count == 3 && d.viewer == "octo-reader")
        #expect(d.comments[0].reactions == [] && d.comments[1].reactions == nil)
        #expect(d.events.map(\.kind) == ["labeled", "assigned"])
        #expect(d.linkedPullRequests.first?.closesIssue == true)
        #expect(d.commentsCursor == "b2xkZXI=")
        #expect(d.summary.ref == IssueRef(projectId: "demo", tracker: "github", host: "github.com", scope: "acme/demo-repo", key: "42"))
    }

    @Test func encodesListInput() {
        var input = IssueListInput()
        input.state = "all"
        input.involvement = "assigned"
        input.limit = 50
        input.query = ""
        input.labels = ["bug"]
        input.cursors = ["github.com acme/demo-repo": "abc"]
        guard case .object(let o) = input.json else { Issue.record("not an object"); return }
        #expect(o["state"] == .string("all") && o["involvement"] == .string("assigned"))
        #expect(o["query"] == nil, "an empty query is left out: the schema wants a non-empty string")
        #expect(o["refresh"] == nil && o["sort"] == nil)
        #expect(o["labels"] == .array([.string("bug")]))
        #expect(o["cursors"] == .object(["github.com acme/demo-repo": .string("abc")]))
    }

    @Test func encodesWrites() {
        let ref = IssueRef(projectId: "demo", tracker: "github", host: nil, scope: "acme/demo-repo", key: "42")
        guard case .object(let u) = IssueWrites.update(ref, labels: ["bug"]) else { Issue.record("update"); return }
        #expect(u["host"] == nil && u["title"] == nil && u["labels"] == .array([.string("bug")]))
        guard case .object(let r) = IssueWrites.react(ref, subjectId: nil, content: "+1", reacted: true) else { Issue.record("react"); return }
        #expect(r["subjectId"] == nil && r["reacted"] == .bool(true))
        guard case .object(let s) = IssueWrites.setState(ref, state: "Closed") else { Issue.record("state"); return }
        #expect(s["state"] == .string("Closed"))
    }

    @Test func linkCommands() {
        let key = ThreadIssueKey(tracker: "github", host: "github.com", scope: "acme/demo-repo", key: "42")
        guard case .object(let l) = IssueWrites.link(threadId: "t1", key: key, projectId: "demo", url: "https://github.com/acme/demo-repo/issues/42",
                                                    displayKey: "#42", title: "Badge", commandId: "c1") else { Issue.record("link"); return }
        #expect(l["type"] == .string("thread.issue.link") && l["source"] == .string("manual") && l["displayKey"] == .string("#42"))
        guard case .object(let u) = IssueWrites.unlink(threadId: "t1", key: key, commandId: "c2") else { Issue.record("unlink"); return }
        #expect(u["type"] == .string("thread.issue.unlink") && u["url"] == nil && u["key"] == .string("42"))
        // `threadIssueKeyOf` folds host and scope case, never the key's.
        let other = ThreadIssueKey(tracker: "github", host: " GitHub.com", scope: "ACME/demo-repo", key: "42")
        #expect(key.normalized == other.normalized)
        #expect(key.normalized != ThreadIssueKey(tracker: "linear", host: "linear.app", scope: "ENG", key: "eng-1").normalized)
    }

    @Test func errorMessages() {
        #expect(IssueFailure.message(tag: "IssueUnavailableError", fields: ["reason": .string("unauthenticated")]) == "This tracker has no working credentials.")
        #expect(IssueFailure.message(tag: "IssueOperationError", fields: ["operation": .string("detail"), "detail": .string("Not Found")])
                == "Issue operation detail failed: Not Found")
        #expect(IssueFailure.message(tag: "Other", fields: [:]) == nil)
    }
}

/// The real 4928 sandbox's answers (fixtures/issues/sandbox-4928.json): no tracker at all.
struct IssueSandboxWireTests {
    @Test func decodesTheSandboxAnswers() throws {
        let root = try IssueWireTests.json("sandbox-4928.json")
        guard case .object(let o) = root else { Issue.record("not an object"); return }
        let list = try #require(o["issuesList"]).decode(as: IssueListResult.self)
        #expect(list.trackers.isEmpty && list.entries.isEmpty && list.scopes == [])
        let trackers = try #require(o["issueTrackersList"]).decode(as: IssueTrackerConnectionList.self)
        #expect(trackers.trackers.first?.scopeNoun == "team" && trackers.trackers.first?.connected == false)
        #expect(trackers.bindings.isEmpty)
    }
}
