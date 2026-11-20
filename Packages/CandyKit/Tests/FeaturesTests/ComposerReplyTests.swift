import Foundation
import Testing
@testable import Features
import T3Protocol

/// Reply to an assistant response (#33124 at 4928).
struct ComposerReplyTests {
    @Test func recordCarriesTheOpeningAndItemId() throws {
        let text = "  " + String(repeating: "a", count: 320)
        let record = try #require(ComposerReply.record(environmentId: "env", threadId: "t1", messageId: "m1", text: text, itemId: "i1", subagents: []))
        #expect(record["kind"]?.stringValue == "response")
        #expect(record["contextId"]?.stringValue == "response_m1")
        #expect(record["itemId"]?.stringValue == "i1")
        #expect(record["citation"]?["text"]?.stringValue?.count == 300)
        #expect(record["citation"]?["start"]?.intValue == 1) // normalized whitespace, as createAssistantTextSelector counts
        #expect(record["label"]?.stringValue?.count == 64)
        #expect(record["subagents"] == nil)
        #expect(ComposerReply.bannerTitle(record) == "Replying to")
        #expect(ComposerReply.record(environmentId: "env", threadId: "t1", messageId: "m1", text: "  \n", itemId: "i1", subagents: []) == nil)
    }

    @Test func promptLeadsWithOneReferenceAndFailedSendDropsIt() throws {
        let record = try #require(ComposerReply.record(environmentId: "env", threadId: "t1", messageId: "m1", text: "Hello there", itemId: "i1", subagents: []))
        let sent = ComposerReply.prompt("why?", replyingTo: record)
        #expect(sent == "[Hello there](t3-context://v1/response/response_m1) why?")
        #expect(ComposerReply.prompt(sent, replyingTo: record) == sent)
        #expect(ComposerReply.draftText(sent, contextId: "response_m1") == "why?")
    }

    @Test func subagentsComeFromTheInputsBeforeTheResponse() throws {
        func item(_ id: String, _ type: String, _ extra: String = "") -> String {
            #"{"position":0,"visibility":"local","sourceThreadId":"t1","sourceItemId":"\#(id)","item":{"id":"\#(id)","threadId":"t1","type":"\#(type)","ordinal":0,"status":"completed","updatedAt":"2026-01-01T00:00:00.000Z"\#(extra)}}"#
        }
        let items = [
            item("s1", "subagent", #","subagentId":"task-1","childThreadId":"child-1""#),
            item("u1", "user_message", #","messageId":"msg-u""#),
            item("n1", "notification", #","source":{"kind":"subagent","childThreadId":"child-1","taskIds":["task-2"]}"#),
            item("a1", "assistant_message", #","messageId":"msg-a""#),
        ].joined(separator: ",")
        let projection = try JSONDecoder().decode(ThreadProjection.self, from: Data("""
            {"thread":{"id":"t1","title":"T"},"runs":[],"attempts":[],"nodes":[],
             "subagents":[{"id":"task-2","childThreadId":null,"remoteChild":{"threadId":"remote-1","environmentId":"env-2","title":"Remote"}}],
             "providerSessions":[],"providerThreads":[],"providerTurns":[],"runtimeRequests":[],"messages":[],"plans":[],
             "turnItems":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],"contextTransfers":[],
             "visibleTurnItems":[\(items)],"updatedAt":"2026-01-01T00:00:00.000Z"}
            """.utf8))
        let found = ComposerReply.subagents(projection, itemId: TurnItemId("a1")) { _, id in id == "child-1" ? "Child" : nil }
        #expect(found == [ComposerReply.Subagent(threadId: "child-1", title: "Child"),
                          ComposerReply.Subagent(threadId: "remote-1", environmentId: "env-2", title: "Remote")])
        let record = try #require(ComposerReply.record(environmentId: "env", threadId: "t1", messageId: "m", text: "x", itemId: "a1", subagents: found))
        #expect(ComposerReply.bannerTitle(record) == "Replying to Child, Remote")
    }
}
