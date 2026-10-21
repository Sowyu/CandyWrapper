import Foundation
import Testing
@testable import T3Client

/// The browser's owner keeps its client, and the client's event closures reach back to the owner
/// (BrowserController's `Stream`). Stopping the client must break that loop so both go away.
@MainActor
struct PreviewStreamClientTests {
    final class Owner {
        var client: PreviewStreamClient?
        var messages = 0
    }

    func makeOwner() -> Owner {
        let owner = Owner()
        var events = PreviewStreamClient.Events()
        events.onMessage = { _ in owner.messages += 1 }
        events.onUnauthorized = { _ = owner }
        owner.client = PreviewStreamClient(url: { throw URLError(.badURL) }, events: events)
        return owner
    }

    @Test func stoppedClientIsReleased() async throws {
        weak var owner: Owner?
        weak var client: PreviewStreamClient?
        do {
            let o = makeOwner()
            owner = o
            client = o.client
            o.client?.start()
            try await Task.sleep(for: .milliseconds(20))
            o.client?.stop()
        }
        // The run task lets go of the client once its cancelled retry sleep returns.
        for _ in 0..<100 where owner != nil || client != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(owner == nil)
        #expect(client == nil)
    }

    @Test func neverStartedClientIsReleasedAfterStop() {
        weak var owner: Owner?
        do {
            let o = makeOwner()
            owner = o
            o.client?.stop()
        }
        #expect(owner == nil)
    }
}
