import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// Ports of 5258 client-runtime threadRepositories.test.ts for the read-only slice: repository scopes, their
/// changed order, the visible four and the section summary.
@Suite struct ThreadRepositoriesTests {
    private func projection(scopes: String, checkpoints: String = "[]") -> ThreadProjection {
        decode(ThreadProjection.self, """
            {"thread":{"id":"t","title":"T"},"runs":[],"attempts":[],"nodes":[],"subagents":[],
             "providerSessions":[],"providerThreads":[],"providerTurns":[],"runtimeRequests":[],"messages":[],"plans":[],
             "turnItems":[],"checkpointScopes":\(scopes),"checkpoints":\(checkpoints),"contextHandoffs":[],"contextTransfers":[],
             "visibleTurnItems":[],"updatedAt":"2026-01-01T00:00:00.000Z"}
            """)
    }
    private func scope(_ id: String, _ path: String?, label: String? = nil) -> String {
        let repo = path.map { #","repositoryPath":"\#($0)""# } ?? ""
        let l = label.map { #","label":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","threadId":"t","kind":"manual","cwd":"\#(path ?? "/w")"\#(repo)\#(l)}"#
    }
    private func checkpoint(_ id: String, scope: String, ordinal: Int) -> String {
        #"{"id":"\#(id)","threadId":"t","scopeId":"\#(scope)","runId":"r\#(ordinal)","ordinalWithinScope":\#(ordinal),"ref":"x","status":"ready","files":[],"capturedAt":"2026-01-01T00:00:00.000Z"}"#
    }

    @Test func listsRepositoryScopesByName() {
        let p = projection(scopes: "[\(scope("root", nil)),\(scope("b", "/w/repo-b")),\(scope("a", "/w/repo-a", label: "Alpha"))]")
        #expect(ThreadRepositories.scopes(p).map(\.name) == ["Alpha", "repo-b"])
    }

    @Test func mostRecentlyChangedComesFirst() {
        let p = projection(scopes: "[\(scope("a", "/w/a")),\(scope("b", "/w/b")),\(scope("c", "/w/c"))]",
                           checkpoints: "[\(checkpoint("1", scope: "a", ordinal: 1)),\(checkpoint("2", scope: "b", ordinal: 3))]")
        #expect(ThreadRepositories.changed(p).map(\.name) == ["b", "a", "c"])
    }

    @Test func showsFourThenTheRest() {
        let changed = (1...6).map { ThreadRepositories.Scope(scopeId: "\($0)", name: "r\($0)", repositoryPath: "/w/r\($0)", cwd: "/w/r\($0)") }
        let folded = ThreadRepositories.sections(changed: changed, threadCwd: "/w/r1", showAll: false)
        #expect(folded.visible.map(\.name) == ["r2", "r3", "r4", "r5"])
        #expect(folded.hidden.map(\.name) == ["r6"])
        #expect(ThreadRepositories.sections(changed: changed, threadCwd: nil, showAll: true).visible.count == 6)
    }

    @Test func summarizesAStatus() {
        let status: JSONValue = .object(["isRepo": .bool(true), "refName": .string("main"), "pr": .object(["number": .number(12)]),
                                         "workingTree": .object(["files": .array([.object([:])]), "insertions": .number(3), "deletions": .number(1)])])
        #expect(ThreadRepositories.Summary(status: status) == .init(branch: "main", isRepository: true, changedFiles: 1, insertions: 3, deletions: 1, pullRequestNumber: 12))
        #expect(ThreadRepositories.Summary(status: nil) == nil)
    }
}
