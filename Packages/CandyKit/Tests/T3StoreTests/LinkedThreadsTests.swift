import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Linked threads read through a linked environment (5258 client-runtime linkedThread.ts, linkedThreadSurface.ts,
/// rightPanelStore.ts:883-913): the tab's id and title, how a link opens, and failures in the user's words.
struct LinkedThreadsTests {
    let target = LinkedThreadSurfaceTarget(viaEnvironmentId: "env a", environmentId: "env-b", threadId: "t/1", label: "Studio")

    @Test func surfaceIdEncodesEachPart() {
        // linkedThreadSurface.ts:10-12: `encodeURIComponent` of each part.
        #expect(RightPanelSurface.linkedThread(target).id == "linked-thread:env%20a:env-b:t%2F1")
    }

    @Test func titleIsTheThreadsOwnElseWhereItIs() {
        #expect(RightPanelSurface.linkedThread(target).title == "Thread on Studio")
        var titled = target
        titled.title = "  Fix the build "
        #expect(RightPanelSurface.linkedThread(titled).title == "Fix the build")
    }

    @Test func openingAgainKeepsAKnownTitleAndOneTab() {
        var state = RightPanelState()
        var titled = target
        titled.title = "Fix the build"
        state.openLinkedThread(titled)
        state.openLinkedThread(target)
        #expect(state.surfaces.count == 1)
        #expect(state.surfaces[0].linkedThread?.title == "Fix the build")
        #expect(state.activeSurfaceId == target.surfaceId && state.isOpen)
        let changed = state.setLinkedThreadTitle(target.surfaceId, title: "Renamed")
        let again = state.setLinkedThreadTitle(target.surfaceId, title: "Renamed")
        #expect(changed && !again)
        #expect(state.surfaces[0].title == "Renamed")
    }

    @Test func savedPanelRoundTrips() throws {
        var state = RightPanelState()
        state.openLinkedThread(target)
        let back = try JSONDecoder().decode(RightPanelState.self, from: JSONEncoder().encode(state))
        #expect(back == state)
    }

    @Test func openRules() {
        // linkedThread.ts:50-62.
        #expect(LinkedThreads.resolveOpen(environmentId: "a", viaEnvironmentId: "a", ownConnected: nil, linked: true) == .direct)
        #expect(LinkedThreads.resolveOpen(environmentId: "b", viaEnvironmentId: "a", ownConnected: true, linked: true) == .direct)
        #expect(LinkedThreads.resolveOpen(environmentId: "b", viaEnvironmentId: "a", ownConnected: false, linked: true) == .linked)
        #expect(LinkedThreads.resolveOpen(environmentId: "b", viaEnvironmentId: "a", ownConnected: nil, linked: false) == .unavailable)
        #expect(LinkedThreads.resolveOpen(environmentId: "b", viaEnvironmentId: "a", ownConnected: false, linked: false) == .direct)
    }

    private func readError(_ reason: String, label: String? = nil, message: String = "") -> RPCTypedError {
        var fields: [String: JSONValue] = ["reason": .string(reason), "message": .string(message)]
        if let label { fields["label"] = .string(label) }
        return RPCTypedError(tag: PeerLinkRPC.threadReadErrorTag, fields: fields)
    }

    @Test func failuresInTheUsersWords() {
        let unreachable = LinkedThreads.failure(readError("unreachable", message: "timed out"), message: "", via: "Laptop", label: "Studio")
        #expect(unreachable == .init(title: "Studio is not answering Laptop", detail: "timed out", retryable: true))
        let expired = LinkedThreads.failure(readError("expired", label: "Studio Mac"), message: "", via: "Laptop", label: "Studio")
        #expect(expired.title == "The link from Laptop to Studio Mac expired")
        #expect(expired.detail == "Link it again in Laptop's Settings → Connections with a new pairing code.")
        #expect(!expired.retryable)
        #expect(LinkedThreads.failure(readError("thread_not_found"), message: "", via: "Laptop", label: "Studio")
            == .init(title: "This thread is no longer on Studio", detail: "It may have been deleted there.", retryable: false))
        #expect(LinkedThreads.failure(readError("disabled"), message: "", via: "Laptop", label: "Studio").title == "Linked environments is off on Laptop")
        // An environment from before this read answers with an unknown method.
        let old = LinkedThreads.failure(nil, message: "", via: "Laptop", label: "Studio")
        #expect(old == .init(title: "Could not read this thread through Laptop",
                             detail: "Laptop may need an update before it can read linked threads.", retryable: true))
        #expect(LinkedThreads.isUnreachable(readError("unreachable")))
        #expect(!LinkedThreads.isUnreachable(readError("rejected")))
    }

    @Test func barStatus() {
        #expect(LinkedThreads.status(label: "Studio", via: "Laptop", working: false) == "On Studio via Laptop")
        #expect(LinkedThreads.status(label: "Studio", via: "Laptop", working: true) == "On Studio via Laptop · Working")
    }
}
