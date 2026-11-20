import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// 4928 thread events: `thread.visit-recorded`, `thread.tags-updated` and `thread.issue-synced`
/// (orchestrationV2.ts:2012-2033, orchestrationV2Projection.ts:317-333).
struct ThreadEvents4928Tests {
    static let thread = #"{"id":"thread-1","title":"T","lastVisitedAt":null,"opens":{"count":1}}"#

    static func projection() throws -> ThreadProjection {
        try JSONDecoder().decode(ThreadProjection.self, from: Data("""
            {"thread":\(thread),"runs":[],"attempts":[],"nodes":[],"subagents":[],
             "providerSessions":[],"providerThreads":[],"providerTurns":[],"runtimeRequests":[],"messages":[],"plans":[],
             "turnItems":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],"contextTransfers":[],
             "visibleTurnItems":[],"updatedAt":"2026-01-01T00:00:00.000Z"}
            """.utf8))
    }

    static func item(_ type: String, _ payload: String) throws -> ThreadStreamItem {
        try JSONDecoder().decode(ThreadStreamItem.self, from: Data("""
            {"kind":"event","sequence":5,"event":{"id":"e1","type":"\(type)","threadId":"thread-1",
             "occurredAt":"2026-02-01T00:00:00.000Z","payload":\(payload)}}
            """.utf8))
    }

    static func event(_ item: ThreadStreamItem) throws -> ThreadEvent {
        guard case .event(_, let event) = item else { throw CancellationError() }
        return event
    }

    @Test func visitRecordedMergesIntoTheHeldThread() throws {
        let p = try Self.projection()
        let visit = try Self.event(Self.item("thread.visit-recorded", #"{"lastVisitedAt":"2026-02-01T00:00:00.000Z","opens":{"count":2}}"#))
        let next = try #require(ThreadReduction.apply(p, visit))
        #expect(next.thread.raw["lastVisitedAt"]?.stringValue == "2026-02-01T00:00:00.000Z")
        #expect(next.thread.raw["opens"]?["count"]?.intValue == 2)
        #expect(next.thread.title == "T")
        #expect(next.updatedAt == p.updatedAt)

        // `opens` is optional and keeps the held value when absent.
        let bare = try Self.event(Self.item("thread.visit-recorded", #"{"lastVisitedAt":"2026-02-02T00:00:00.000Z"}"#))
        let again = try #require(ThreadReduction.apply(next, bare))
        #expect(again.thread.raw["opens"]?["count"]?.intValue == 2)
        #expect(again.thread.raw["lastVisitedAt"]?.stringValue == "2026-02-02T00:00:00.000Z")
    }

    /// `thread.pull-request-link-updated` replaces the link with the same key (orchestrationV2Projection.ts:297-301).
    @Test func pullRequestLinkUpdateReplacesItsLink() throws {
        var p = try Self.projection()
        p.thread = try JSONValue(parsing: Data(#"{"id":"thread-1","title":"T","pullRequests":[{"host":"github.com","repository":"a/b","number":1,"url":"u1","source":"manual","linkedAt":"2026-01-01T00:00:00.000Z","snapshot":null,"stack":null},{"host":"github.com","repository":"a/b","number":2,"url":"u2","source":"manual","linkedAt":"2026-01-01T00:00:00.000Z","snapshot":null,"stack":null}]}"#.utf8)).decode(as: AppThread.self)
        let update = try Self.event(Self.item("thread.pull-request-link-updated",
            #"{"host":"GitHub.com","repository":"A/B","number":2,"url":"u2-new","source":"agent","linkedAt":"2026-02-01T00:00:00.000Z","snapshot":null,"stack":null}"#))
        let next = try #require(ThreadReduction.apply(p, update))
        #expect(next.thread.raw["pullRequests"]?.arrayValue?.map { $0["url"]?.stringValue } == ["u1", "u2-new"])
    }

    @Test func tagsAndIssueEventsCarryTheWholeThread() throws {
        let p = try Self.projection()
        let tagged = try Self.event(Self.item("thread.tags-updated",
            #"{"id":"thread-1","title":"T","tags":["infra","ux",3],"lastTitleRegeneration":{"status":"renamed","requestId":"c1","completedAt":"2026-02-01T00:00:00.000Z"}}"#))
        let next = try #require(ThreadReduction.apply(p, tagged))
        #expect(next.thread.tags == ["infra", "ux"])
        #expect(next.thread.lastTitleRegeneration?.status == "renamed")
        #expect(next.updatedAt == p.updatedAt)

        let synced = try Self.event(Self.item("thread.issue-synced", #"""
            {"id":"thread-1","title":"T","issues":[{"tracker":"github","host":"github.com","scope":"o/r","key":"12",
             "projectId":"p1","url":"https://github.com/o/r/issues/12","source":"agent","linkedAt":"2026-02-01T00:00:00.000Z",
             "displayKey":"#12","title":"Bug"},{"tracker":"github"}]}
            """#))
        let issued = try #require(ThreadReduction.apply(next, synced))
        #expect(issued.thread.issues.map(\.displayKey) == ["#12"])
        #expect(issued.updatedAt == synced.occurredAt)
    }

    @Test func shellDecodesTagsIssuesAndTitleOutcomeLeniently() throws {
        let shell = try JSONDecoder().decode(LenientArray<String>.self, from: Data(#"{"not":"an array"}"#.utf8))
        #expect(shell.values.isEmpty)
        let outcome = try JSONDecoder().decode(LastTitleRegeneration.self, from: Data(
            #"{"status":"failed","message":"no model","requestId":"c","completedAt":"2026-02-01T00:00:00.000Z"}"#.utf8))
        #expect(outcome.message == "no model")
    }
}
