import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Side chats (4928 #26901): the fork, discard and mode payloads, `/side` parsing, when one may start, the tab's
/// dot, the open route and the right panel's `side-chat` surface.
struct SideChatsTests {
    @Test func forkPayloadMatchesForkSideChat() {
        let payload = SideChats.fork(source: "thread-a", target: "thread-b", commandId: "c1")
        // client-runtime operations/commands.ts:1100-1115.
        #expect(payload == .object(["type": .string("thread.fork"), "commandId": .string("c1"), "createdBy": .string("user"),
                                    "creationSource": .string("web"), "sourceThreadId": .string("thread-a"),
                                    "targetThreadId": .string("thread-b"), "sourcePoint": .object(["type": .string("latest_stable")]),
                                    "sideChat": .bool(true), "title": .string("Side chat")]))
    }

    @Test func failedStartDiscardsOnlyAnUnusedThread() {
        #expect(SideChats.discard("thread-b", commandId: "c2") == .object([
            "type": .string("thread.delete"), "commandId": .string("c2"), "threadId": .string("thread-b"), "onlyIfUnused": .bool(true)]))
        #expect(SideChats.setRuntimeMode("thread-b", "approval-required", commandId: "c3")["type"] == .string("thread.runtime-mode.set"))
    }

    @Test(arguments: [
        ("/side", ""), ("/btw", ""), ("/side what is this?", "what is this?"), ("/BTW  hi there ", "hi there"),
        ("  /side\nline two", "line two"), ("/Side x", "x"),
    ])
    func parsesSideAndBtw(_ text: String, _ prompt: String) {
        #expect(SideChats.parseCommand(text) == prompt)
    }

    @Test(arguments: ["/sidecar", "/btwx hi", "side hi", "hi /side", "/clear", "", "/"])
    func ignoresOtherText(_ text: String) {
        #expect(SideChats.parseCommand(text) == nil)
    }

    @Test func disabledReasonsFollowChatView() {
        typealias P = SideChats.Parent
        #expect(SideChats.disabledReason(P()) == nil)
        #expect(SideChats.disabledReason(P(isSideChat: true)) == "Side chats cannot start side chats.")
        #expect(SideChats.disabledReason(P(isSubagent: true)) == "Subagent threads cannot start side chats.")
        #expect(SideChats.disabledReason(P(configLoaded: false)) == "Side chats are not ready yet. Try again in a moment.")
        // A 3824 server has no `sideChats` capability and would fork an ordinary listed thread.
        #expect(SideChats.disabledReason(P(capable: false)) == "Update this environment's T3 Code server to use side chats.")
        #expect(!P(capable: false).offered)
        #expect(SideChats.disabledReason(P(isServerThread: false)) == "Side chats start after the first message.")
        #expect(SideChats.disabledReason(P(worktreePending: true)) == "Available once the thread's worktree is set up.")
    }

    @Test func tabStateShowsWaitingBeforeRunning() {
        #expect(SideChats.tabState(nil) == nil)
        #expect(SideChats.tabState(thread { $0.status = .completed }) == nil)
        #expect(SideChats.tabState(thread { $0.status = .running }) == .running)
        let input = PendingRuntimeRequestSummary(id: "r", kind: .userInput, createdAt: "2026-01-01T00:00:00.000Z")
        let approval = PendingRuntimeRequestSummary(id: "r", kind: .command, createdAt: "2026-01-01T00:00:00.000Z")
        #expect(SideChats.tabState(thread { $0.status = .running; $0.pendingRuntimeRequest = input }) == .needsInput)
        #expect(SideChats.tabState(thread { $0.status = .running; $0.pendingRuntimeRequest = approval }) == .needsApproval)
    }

    @Test func titleHelperCleanupPreservesUserSideChats() {
        let own = thread("env-a/helper") {
            $0.title = "Title helper"
            $0.lineage = ThreadLineage(parentThreadId: "parent", relationshipToParent: .fork, rootThreadId: "parent", sideChat: true)
        }
        var other = own
        other.id = "env-b/helper"
        let recorded: Set<ThreadId> = [own.id]
        #expect(DeeperRename.isLeftover(own, owned: recorded))
        #expect(!DeeperRename.isLeftover(other, owned: recorded))
        #expect(!DeeperRename.isLeftover(own, owned: []))
    }

    @Test func aSideChatOpensAsItsParent() {
        let side = thread("thread-side") {
            $0.lineage = ThreadLineage(parentThreadId: "thread-parent", relationshipToParent: .fork, rootThreadId: "thread-parent", sideChat: true)
        }
        let route = SideChats.openRoute("thread-side", shell: side)
        #expect(route.open == "thread-parent" && route.sideChat == "thread-side")
        let fork = thread("thread-fork") { $0.lineage = ThreadLineage(parentThreadId: "thread-parent", relationshipToParent: .fork, rootThreadId: "thread-parent") }
        #expect(SideChats.openRoute("thread-fork", shell: fork).sideChat == nil)
        #expect(SideChats.openRoute("thread-x", shell: nil).open == "thread-x")
    }

    @Test func panelKeepsOneTabPerSideChat() throws {
        var state = RightPanelState()
        state.openSideChat("thread-side")
        state.openSideChat("thread-side")
        #expect(state.surfaces == [.sideChat("thread-side")] && state.activeSurfaceId == "side-chat:thread-side" && state.isOpen)
        #expect(state.active?.kind == .sideChat && state.active?.title == "Side chat")
        // Persisted with the thread's panel like the other tabs.
        let decoded = try JSONDecoder().decode(RightPanelState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(state.close("side-chat:thread-side").first?.sideChatThreadId == "thread-side")
    }
}
