import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

struct CitationHistoryTests {
    private func projection(role: String? = nil) throws -> ThreadProjection {
        var p = try JSONDecoder().decode(ThreadProjection.self, from: Data(#"{"thread":{"id":"t","title":"Thread"},"runs":[],"attempts":[],"nodes":[],"subagents":[],"providerSessions":[],"providerThreads":[],"providerTurns":[],"runtimeRequests":[],"messages":[],"plans":[],"turnItems":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],"contextTransfers":[],"visibleTurnItems":[],"updatedAt":"2026-01-01T00:00:00.000Z"}"#.utf8))
        if let role {
            let item = try JSONDecoder().decode(TurnItem.self, from: Data("{\"id\":\"item\",\"threadId\":\"t\",\"type\":\"\(role)_message\",\"messageId\":\"quoted\",\"runId\":\"run\",\"text\":\"quote\",\"ordinal\":1,\"status\":\"completed\",\"updatedAt\":\"2026-01-01T00:00:00.000Z\"}".utf8))
            p.visibleTurnItems = [ProjectedTurnItem(local: item, position: 0)]
        }
        return p
    }
    @Test func pagesUntilFoundAndCapsWorkAtTwentyPages() throws {
        let history = ThreadHistoryMeta(historyCursor: "older", hasMoreHistory: true)
        let p = try projection()
        #expect(CitationHistory.step(messageId: "quoted", projection: nil, history: history, status: .synchronizing, pages: 0) == .waiting)
        #expect(CitationHistory.step(messageId: "quoted", projection: p, history: history, status: .live, pages: 19) == .loadEarlier)
        #expect(CitationHistory.step(messageId: "quoted", projection: p, history: history, status: .live, pages: 20) == CitationHistory.couldNotLoad)
        let found = try projection(role: "assistant")
        #expect(found.messages.isEmpty)
        #expect(CitationHistory.step(messageId: "quoted", projection: found, history: history, status: .live, pages: 20) == .found(entryId: "quoted", runId: "run"))
        #expect(CitationHistory.step(messageId: "quoted", projection: p, history: .init(), status: .live, pages: 0) == CitationHistory.unavailable)
    }
    @Test func failuresAndNonAssistantTargetsKeepTheQuote() throws {
        var history = ThreadHistoryMeta(historyCursor: "older", hasMoreHistory: true)
        history.loading = true
        #expect(CitationHistory.step(messageId: "quoted", projection: try projection(), history: history, status: .live, pages: 0) == .waiting)
        history.loading = false; history.error = "offline"
        #expect(CitationHistory.step(messageId: "quoted", projection: try projection(), history: history, status: .live, pages: 0) == CitationHistory.couldNotLoad)
        #expect(CitationHistory.step(messageId: "quoted", projection: try projection(role: "user"), history: .init(), status: .live, pages: 0) == .failed(title: "The citation does not refer to an assistant response", message: "The selected text is still saved in your citation."))
    }
}
