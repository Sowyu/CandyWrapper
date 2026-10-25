import Foundation
import Testing
import SpaceModel
@testable import SpaceEngine

/// Page history from the log and the change that restores a version (docs/space.md section 9).
struct SpaceHistoryTests {
    let page = PageID(), other = PageID()
    let mac = DeviceID(), phone = DeviceID()
    let minute: Int64 = 60_000

    func block(_ id: BlockID, _ text: String, on page: PageID? = nil, order: String = "a0") -> RecordChange {
        try! RecordChange.block(id, BlockRecord(page: page ?? self.page, order: try! OrderKey(order), text: RichText(t: text)))
    }
    func setText(_ id: BlockID, _ text: String) -> RecordChange {
        RecordChange(kind: .block, id: id, set: ["text": try! JSONValue(encoding: RichText(t: text))])
    }
    func op(_ device: DeviceID, _ at: Int64, _ changes: RecordChange...) -> (device: DeviceID, payload: OpPayload) {
        (device, OpPayload(at: at, changes: changes))
    }

    @Test func versionsGroupByDeviceAndTenMinuteStretch() throws {
        let a = BlockID(), b = BlockID(), elsewhere = BlockID()
        let ops = [
            op(mac, 0, try RecordChange.page(page, PageRecord(order: try OrderKey("a0"), title: "Plan", created: 0)), block(a, "One")),
            op(mac, 2 * minute, setText(a, "One two")),
            op(mac, 5 * minute, block(elsewhere, "Not this page", on: other)),
            op(mac, 9 * minute, setText(a, "One two three")),
            // Ten minutes after the stretch began: a new version.
            op(mac, 10 * minute, block(b, "Second", order: "a1")),
            op(phone, 11 * minute, setText(b, "Second from phone")),
        ]
        let versions = SpaceHistory.versions(of: page, base: SpaceState(), ops: ops)
        #expect(versions.map(\.edits) == [1, 1, 3])
        #expect(versions.map(\.device) == [phone, mac, mac])
        #expect(versions.map(\.index) == [6, 5, 4])
        #expect(versions[2].started == 0 && versions[2].at == 9 * minute)
        let oldest = versions[2].state
        #expect(oldest.text(of: a).t == "One two three")
        #expect(oldest.blocks[b] == nil && oldest.blocks[elsewhere] == nil)
        #expect(oldest.page(page)?.title == "Plan")
        #expect(versions[0].state.text(of: b).t == "Second from phone")
    }

    @Test func restoreSetsBlocksBackTrashesAddedAndRevivesTrashed() throws {
        let a = BlockID(), b = BlockID(), c = BlockID()
        var ops = [
            op(mac, 0, try RecordChange.page(page, PageRecord(order: try OrderKey("a0"), title: "Plan", created: 0)),
               block(a, "Keep me"), block(b, "Then deleted", order: "a1")),
        ]
        ops.append(op(mac, 20 * minute, setText(a, "Rewritten"), RecordChange(kind: .block, id: b, set: ["trashed": .bool(true)]),
                      block(c, "Added later", order: "a2"), RecordChange(kind: .page, id: page, set: ["title": .string("Plan v2")])))
        var current = SpaceState()
        for o in ops { current.apply(o.payload.changes) }
        let versions = SpaceHistory.versions(of: page, base: SpaceState(), ops: ops)
        #expect(versions.count == 2)

        let changes = SpaceHistory.restore(versions[1], in: current)
        current.apply(changes)
        #expect(current.text(of: a).t == "Keep me")
        #expect(current.block(b)?.trashed == false)
        #expect(current.block(c)?.trashed == true)
        #expect(current.page(page)?.title == "Plan")
        // Restoring the version the page is already at changes nothing.
        #expect(SpaceHistory.restore(versions[1], in: current).isEmpty)
    }

    @Test func historyStartsFromTheSnapshotsBlocks() throws {
        let a = BlockID()
        var base = SpaceState()
        base.apply([try RecordChange.page(page, PageRecord(order: try OrderKey("a0"), title: "Old", created: 0)), block(a, "Before")])
        let versions = SpaceHistory.versions(of: page, base: base, ops: [op(mac, minute, setText(a, "After"))])
        #expect(versions.count == 1)
        #expect(versions[0].state.text(of: a).t == "After")
    }
}
