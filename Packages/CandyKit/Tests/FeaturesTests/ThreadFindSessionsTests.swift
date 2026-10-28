import Testing
import T3Protocol
@testable import Features

struct ThreadFindSessionsTests {
    @Test func switchingThreadsRetainsTheirQueryAndMatchAndCloseClearsOnlyOne() {
        var sessions = ThreadFindSessions()
        let a = ThreadId("same").scoped(to: "a"), b = ThreadId("same").scoped(to: "b")
        let result = ThreadFindResult(totalMatches: 5, activeIndex: 3, match: .init(entryId: "older", runId: "run", occurrence: 2))
        sessions[a] = .init(query: "needle", result: result)
        sessions[b] = .init(query: "other", result: nil)
        #expect(sessions[a]?.result?.match?.entryId == "older")
        #expect(sessions[a]?.result?.match?.occurrence == 2)
        #expect(sessions[a]?.query == "needle")
        sessions[b] = nil
        #expect(sessions[a]?.result?.activeIndex == 3)
        #expect(sessions[b] == nil)
    }
}
