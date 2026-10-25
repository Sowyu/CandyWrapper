import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// The owner's side of T3 3669's guest share (fb76594d7b): the projection's `thread.guestShare` and its update
/// event, the shell's waiting count, the commands T3's client sends, and how sent guest messages and the sidebar read.
/// Fixtures follow packages/contracts/src/guestShare.ts and composerContext.ts at 3669.
@Suite struct GuestShareTests {
    static let share = """
        {"id":"share-1","host":"abc.t3.tunnel","createdAt":"2026-10-25T10:00:00.000Z","expiresAt":"2026-10-26T10:00:30.000Z",
         "guestName":null,"messages":[
           {"id":"gm-1","text":"Can you add tests?","status":"pending","submittedAt":"2026-10-25T10:05:00.000Z"},
           {"id":"gm-2","text":"Old one","status":"sent","submittedAt":"2026-10-25T10:01:00.000Z"},
           {"id":"gm-3","text":"","status":"pending","submittedAt":"2026-10-25T10:06:00.000Z",
            "attachments":[{"type":"image","id":"att-1","name":"shot.png","mimeType":"image/png","sizeBytes":10}]}]}
        """

    static func threadEvent(guestShare: String, sequence: Int = 5) -> String {
        """
        {"kind":"event","sequence":\(sequence),"event":{"id":"e\(sequence)","type":"thread.guest-share-updated","threadId":"thread-1",
         "runId":null,"occurredAt":"2026-10-25T10:06:00.000Z","payload":{"id":"thread-1","title":"T","guestShare":\(guestShare)}}}
        """
    }

    @Test func projectionDecodesTheShareAndOlderServersHaveNone() throws {
        let thread = decode(AppThread.self, #"{"id":"thread-1","title":"T","guestShare":\#(Self.share)}"#)
        let share = try #require(thread.guestShare)
        #expect(share.host == "abc.t3.tunnel")
        #expect(share.pendingMessages.map(\.id) == ["gm-1", "gm-3"])
        #expect(share.messages[2].attachments?.count == 1)
        #expect(decode(AppThread.self, #"{"id":"thread-1","title":"T"}"#).guestShare == nil)
        #expect(decode(AppThread.self, #"{"id":"thread-1","title":"T","guestShare":null}"#).guestShare == nil)
    }

    @Test func updateEventReplacesTheThreadInTheReducer() throws {
        let item = decode(ThreadStreamItem.self, Self.threadEvent(guestShare: Self.share))
        guard case .event(_, let event) = item, case .thread(let thread) = event.payload else {
            Issue.record("guest-share-updated decoded as \(item)")
            return
        }
        #expect(event.type.carriesThread)
        #expect(thread.guestShare?.pendingMessages.count == 2)
        // A closed share arrives as the thread without it.
        let closed = decode(ThreadStreamItem.self, Self.threadEvent(guestShare: "null", sequence: 6))
        guard case .event(_, let closedEvent) = closed, case .thread(let closedThread) = closedEvent.payload else {
            Issue.record("closed share decoded as \(closed)")
            return
        }
        #expect(closedThread.guestShare == nil)
    }

    /// `GuestShareStatus` (GuestShareControls.tsx:216-223): the guest's name once redeemed, and expired from the
    /// expiry's minute on.
    @Test func headerStatus() throws {
        var share = decode(ThreadGuestShare.self, Self.share)
        let before = Date(timeIntervalSince1970: TimeInterval(ms("2026-10-26T09:59:59.000Z")) / 1000)
        let atMinute = Date(timeIntervalSince1970: TimeInterval(ms("2026-10-26T10:00:00.000Z")) / 1000)
        #expect(share.statusText(now: before) == "Guest link active")
        #expect(share.statusText(now: atMinute) == "Guest link expired")
        #expect(share.expiryDate(after: before) == atMinute)
        #expect(share.expiryDate(after: atMinute) == nil)
        share.guestName = "Sam"
        #expect(share.statusText(now: before) == "Sam is a guest")
        #expect(share.statusText(now: atMinute) == "Guest link expired")
    }

    /// commands.ts:437-474: Stop sharing, Dismiss, and Send as a `message.dispatch` the server fills in.
    @Test func commandsMatchTheClientRuntime() {
        func obj(_ fields: [String: String], _ extra: [String: JSONValue] = [:]) -> JSONValue {
            .object(fields.mapValues { JSONValue.string($0) }.merging(extra) { $1 })
        }
        #expect(ThreadCommands.closeGuestShare("thread-1", commandId: "c1")
            == obj(["type": "thread.guest-share.close", "commandId": "c1", "threadId": "thread-1"]))
        #expect(ThreadCommands.resolveGuestMessage("thread-1", guestMessageId: "gm-1", send: false, commandId: "c2")
            == obj(["type": "thread.guest-message.dismiss", "commandId": "c2", "threadId": "thread-1", "guestMessageId": "gm-1"]))
        #expect(ThreadCommands.resolveGuestMessage("thread-1", guestMessageId: "gm-1", send: true, commandId: "c3")
            == obj(["type": "message.dispatch", "commandId": "c3", "threadId": "thread-1", "messageId": "c3", "guestMessageId": "gm-1",
                    "text": "", "createdBy": "user", "creationSource": "web"],
                   ["attachments": .array([]), "dispatchMode": .object(["type": .string("queue_after_active")])]))
        #expect(ThreadCommands.createGuestShare("thread-1") == obj(["threadId": "thread-1"]))
    }

    @Test func createErrorsShowT3Text() {
        #expect(GuestShareCreateError.message(reason: "connect_unavailable") == "Guest links need a running T3 Connect tunnel.")
        #expect(GuestShareCreateError.message(reason: "disabled") == "Guest links are off. Turn them on in Settings > Beta.")
        #expect(GuestShareCreateError.message(reason: "future") == nil)
    }

    /// userMessage.ts:42-50: people see the guest's words and name; the stored text is for the agent.
    @Test func sentGuestMessagesShowTheGuestsWords() {
        let context: JSONValue = .object(["guest": .object(["guestMessageId": .string("gm-1"), "name": .string("Sam"),
                                                            "text": .string("Can you add tests?"), "shareId": .string("share-1")])])
        let m = ChatMessage(id: MessageId("m"), role: .user, text: "[Sam, a guest, wrote]\nCan you add tests?",
                            createdAt: "2026-10-25T10:07:00.000Z", createdBy: "user", context: context)
        let p = UserMessagePresentation.resolve(m)
        #expect(p.text == "Can you add tests?")
        #expect(p.guestName == "Sam" && p.attribution == .guest)
        #expect(!p.isAutomation)
        #expect(!UserMessagePresentation.isTypedByUser(m))
    }

    /// Sidebar.logic.ts:915-918, 1109-1119: a waiting guest message reads as Request, after the agent's own requests.
    @Test func sidebarStatus() {
        let waiting = sidebarThread { $0.pendingGuestMessageCount = 2 }
        #expect(SidebarModel.resolveSidebarThreadStatus(waiting) == .request)
        #expect(SidebarModel.resolveSidebarV2TopStatus(status: .request, isUnread: false, isWoke: false) == .request)
        #expect(!SidebarModel.shouldRecedeSidebarThread(status: .request, isUnread: false, isWoke: false, isActive: false, isSelected: false))
        #expect(SidebarModel.resolveThreadStatusPill(waiting, lastVisitedAt: nil)?.label == .guestRequest)
        #expect(ThreadStatusPill.Label.guestRequest.rawValue == "Guest Request")
        #expect(SidebarModel.resolveSidebarThreadStatus(sidebarThread { $0.pendingGuestMessageCount = 0 }) != .request)
        #expect(SidebarModel.resolveSidebarThreadStatus(sidebarThread()) != .request)
    }

    @Test func shellDecodesTheWaitingCount() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: Data(baseThreadJSON.utf8)) as? [String: Any])
        json["pendingGuestMessageCount"] = 1
        let shell = try JSONDecoder().decode(ThreadShell.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(shell.pendingGuestMessageCount == 1)
        #expect(baseThread.pendingGuestMessageCount == nil)
    }

    @Test func menuOffersSharingOnlyWhenAvailable() {
        var state = ThreadActionMenu.State()
        #expect(!ThreadActionMenu.items(state).contains { $0.id == "share-guest" })
        state.canShareWithGuest = true
        state.canOperate = false
        let item = ThreadActionMenu.items(state).first { $0.id == "share-guest" }
        #expect(item?.label == "Share with guest")
        #expect(item?.disabled == false)
    }
}
