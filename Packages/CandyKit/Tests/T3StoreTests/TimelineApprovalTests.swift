import Foundation
import Testing
import T3Protocol
@testable import T3Store

struct TimelineApprovalTests {
    @Test func pendingApprovalStaysOnItsRowAndUnmatchedRequestsGoLast() throws {
        let item = try TurnItem(json: .object(["id": .string("item"), "threadId": .string("t"), "runId": .string("r"),
            "type": .string("approval_request"), "requestId": .string("request"), "requestKind": .string("command"),
            "prompt": .string("pwd"), "status": .string("waiting"), "ordinal": .number(1),
            "createdAt": .string("2026-10-28T00:00:00Z"), "updatedAt": .string("2026-10-28T00:00:00Z")]))
        let entries = TimelineEntries.derive(visibleTurnItems: [ProjectedTurnItem(local: item)])
        let approval = PendingApproval(requestId: "request", requestKind: .command, detail: "pwd", canRespond: true)
        let unmatched = PendingApproval(requestId: "unmatched", requestKind: .fileRead, canRespond: false)
        var input = TimelineRowsInput(entries: entries, latestRun: .init(runId: "r", status: .waiting), isWorking: true)
        input.pendingApprovals = [approval, unmatched]
        let rows = TimelineRows.derive(input)
        #expect(rows.contains { $0.id == "item" && $0.kind == .pendingApproval(approval) })
        #expect(rows.last?.kind == .pendingApproval(unmatched))
        #expect(!rows.contains { if case .thinking = $0.kind { true } else { false } })
        var unmatchedOnly = TimelineRowsInput(entries: [], isWorking: true)
        unmatchedOnly.pendingApprovals = [unmatched]
        #expect(TimelineRows.derive(unmatchedOnly).last?.kind == .pendingApproval(unmatched))
        input.pendingApprovals = []
        #expect(!TimelineRows.derive(input).contains { if case .pendingApproval = $0.kind { true } else { false } })
    }
}
