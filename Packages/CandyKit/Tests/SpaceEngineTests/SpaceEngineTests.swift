import Foundation
import Testing
import SpaceModel
@testable import SpaceEngine

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/space")
private func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name + ".json")) }

private func key(_ raw: String) -> OrderKey { try! OrderKey(raw) }
private func text(_ t: String, _ marks: [TextMark] = []) -> RichText { RichText(t: t, m: marks) }
private func json(_ value: some Encodable) -> JSONValue { try! JSONValue(encoding: value) }

/// The Space machine's check-and-append from docs/space.md, in memory. An op it already holds is
/// acknowledged again rather than appended twice.
private struct Host {
    var log: [(frame: LogFrame, payload: OpPayload)] = []
    var revs: [RecordID: Int64] = [:]

    mutating func push(_ op: PendingOp, from device: DeviceID) -> Bool {
        if log.contains(where: { $0.frame.op == op.op }) { return true }
        for rec in op.recs { if let base = rec.base, base != (revs[rec.id] ?? 0) { return false } }
        let seq = Int64(log.count + 1)
        log.append((LogFrame(seq: seq, t: 0, dev: device, op: op.op, recs: op.recs, ct: ""), op.payload))
        for rec in op.recs { revs[rec.id] = seq }
        return true
    }
    func frames(after seq: Int64) -> [(frame: LogFrame, payload: OpPayload)] { Array(log.dropFirst(Int(seq))) }

    mutating func catchUp(_ replica: inout SpaceReplica) throws { try replica.receive(frames(after: replica.confirmed.seq)) }

    /// Catch up, then push each pending op in order, rebasing after a reject (docs/space.md step 4 and 5).
    mutating func sync(_ replica: inout SpaceReplica) throws {
        try catchUp(&replica)
        var attempts = 0
        while let op = replica.pending.first {
            attempts += 1
            #expect(attempts < 50, "sync never settles")
            if attempts >= 50 { return }
            _ = push(op, from: replica.device)
            try catchUp(&replica)
        }
    }
}

/// A seeded generator, so a failing property case can be replayed.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A root page with four child pages and four text blocks, confirmed at seq 1 on both replicas.
private struct World {
    var host = Host()
    var a: SpaceReplica
    var b: SpaceReplica
    let root = PageID()
    let pages = (0..<4).map { _ in PageID() }
    let blocks = (0..<4).map { _ in BlockID() }

    init(texts: [String] = ["Buy milk tomorrow", "Call the 😀 plumber", "", "Pack bags"]) throws {
        a = SpaceReplica(device: DeviceID(), label: "MacBook")
        b = SpaceReplica(device: DeviceID(), label: "Mac mini")
        var changes = [try RecordChange.page(root, PageRecord(order: key("a0"), title: "Root", created: 1))]
        for (i, page) in pages.enumerated() {
            changes.append(try .page(page, PageRecord(parent: root, order: key("b\(i)"), title: "Page \(i)", created: 1)))
        }
        for (i, block) in blocks.enumerated() {
            changes.append(try .block(block, BlockRecord(page: root, order: key("a\(i + 1)"), text: text(texts[i]))))
        }
        try a.edit(changes, at: 1)
        try host.sync(&a)
        try host.sync(&b)
    }
}

struct SpaceEngineTests {
    // MARK: Apply

    @Test func snapshotFixtureRoundTripsAndAppliesTheOpFixture() throws {
        let source = try data("snapshot")
        var state = try SpaceJSON.decode(SpaceState.self, from: source)
        #expect(try SpaceJSON.encode(state) == source)
        #expect(try SpaceState(snapshot: SpaceJSON.decode(SnapshotPayload.self, from: source)) == state)

        var frame = try SpaceJSON.decode(LogFrame.self, from: data("frame"))
        frame.seq = state.seq + 1
        let payload = try SpaceJSON.decode(OpPayload.self, from: data("op"))
        try state.apply(frame, payload)

        let page = try RecordID("00000000-0000-4000-8000-000000000001")
        let block = try RecordID("00000000-0000-4000-8000-000000000006")
        #expect(state.revs[page] == frame.seq && state.revs[block] == frame.seq)
        #expect(state.page(page)?.title == "Groceries")
        #expect(state.page(page)?.fields["done"]?.order == key("a2"))
        #expect(state.text(of: block).t == "😀 Buy milk tomorrow")
        #expect(state.blocks[block]?["lang"] == nil, "null removes the key")
        // An unknown two-level path sets inside the unknown object and keeps its siblings.
        guard case .object(let future)? = state.pages[page]?["future"] else { Issue.record("future lost"); return }
        #expect(future["huge"] == .integer(9_007_199_254_740_993))
        #expect(future["nested"] == .object(["keep": .array([.integer(1), .null])]))
        // The typed snapshot still reads every record.
        let typed = try SpaceJSON.decode(SnapshotPayload.self, from: SpaceJSON.encode(state))
        #expect(typed.pages.count == 2 && typed.blocks.count == 11)

        frame.seq += 5
        #expect(throws: ApplyError.gap(expected: state.seq + 1, got: frame.seq)) { try state.apply(frame, payload) }
    }

    @Test func ownConfirmationsDropPendingAndKeepTheScreen() throws {
        var replica = SpaceReplica(device: DeviceID(), label: "Mac")
        let page = PageID(), block = BlockID()
        try replica.edit([try RecordChange.page(page, PageRecord(order: key("a0"), title: "Plan", created: 1))], at: 1)
        try replica.edit([try RecordChange.block(block, BlockRecord(page: page, order: key("a1"), text: text("Hi")))], at: 2)
        let undo = try replica.edit([RecordChange(kind: .block, id: block, set: ["text": json(text("Hi there"))])], at: 3)
        let screen = replica.current
        // The local writer confirms every op as it was made, so the frames carry the same ops and payloads.
        let frames = replica.pending.enumerated().map { i, op in
            (frame: LogFrame(seq: Int64(i + 1), t: 0, dev: replica.device, op: op.op, recs: op.recs, ct: ""), payload: op.payload)
        }
        // Only the first two came back so far.
        #expect(try replica.confirmOwn(Array(frames.prefix(2))))
        #expect(replica.pending.count == 1 && replica.confirmed.seq == 2 && replica.current == screen)
        #expect(try replica.confirmOwn(Array(frames.dropFirst(2))))
        #expect(replica.pending.isEmpty && replica.confirmed.pages == screen.pages && replica.confirmed.blocks == screen.blocks)
        // Undo entries outlive the ops they came from.
        try replica.undo(undo, at: 4)
        #expect(replica.current.text(of: block).t == "Hi")
        // Frames that aren't this replica's oldest pending ops change nothing.
        let other = LogFrame(seq: 3, t: 0, dev: DeviceID(), op: OpID(), recs: [], ct: "")
        let before = replica
        #expect(try !replica.confirmOwn([(other, OpPayload(at: 0, changes: []))]))
        #expect(replica == before)
    }

    @Test func pathsApplyInByteOrderAndNullRemoves() {
        let id = PageID()
        var state = SpaceState()
        state.apply([RecordChange(kind: .page, id: id, set: ["props.x": .integer(1), "props": .object(["y": .integer(2)])])])
        #expect(state.pages[id]?["props"] == .object(["x": .integer(1), "y": .integer(2)]))
        state.apply([RecordChange(kind: .page, id: id, set: ["props.y": .null, "props.z": .null, "icon": .null])])
        #expect(state.pages[id]?["props"] == .object(["x": .integer(1)]))
        #expect(state.pages[id]?["icon"] == nil)
    }

    @Test func movingAPageUnderItsOwnDescendantIsIgnored() throws {
        var world = try World()
        let (root, p0, p1) = (world.root, world.pages[0], world.pages[1])
        try world.a.edit([RecordChange(kind: .page, id: p1, set: ["parent": .string(p0.rawValue)])], at: 2)
        #expect(world.a.current.parent(of: p1) == p0)
        // Root under its grandchild, and a page under itself: both keep their parent, the rest applies.
        try world.a.edit([RecordChange(kind: .page, id: root, set: ["parent": .string(p1.rawValue), "title": .string("Moved?")])], at: 3)
        try world.a.edit([RecordChange(kind: .page, id: p0, set: ["parent": .string(p0.rawValue)])], at: 4)
        #expect(world.a.current.parent(of: root) == nil)
        #expect(world.a.current.page(root)?.title == "Moved?")
        #expect(world.a.current.parent(of: p0) == root)

        // Two devices make crossing moves offline. Each is fine alone; seq order decides, the same everywhere.
        try world.host.sync(&world.a)
        try world.host.sync(&world.b)
        let p2 = world.pages[2], p3 = world.pages[3]
        try world.a.edit([RecordChange(kind: .page, id: p2, set: ["parent": .string(p3.rawValue)])], at: 5)
        try world.b.edit([RecordChange(kind: .page, id: p3, set: ["parent": .string(p2.rawValue)])], at: 5)
        try world.host.sync(&world.a)
        try world.host.sync(&world.b)
        try world.host.sync(&world.a)
        #expect(world.a.confirmed == world.b.confirmed)
        #expect(world.a.confirmed.parent(of: p2) == p3)
        #expect(world.a.confirmed.parent(of: p3) == root, "the later move would close a cycle")
    }

    @Test func aPageWhoseParentIsMissingShowsAtTheTop() {
        var state = SpaceState()
        let page = PageID()
        state.apply([RecordChange(kind: .page, id: page, set: ["parent": .string(PageID().rawValue)])])
        #expect(state.parent(of: page) == nil)
    }

    // MARK: Text merge

    @Test func nonOverlappingEditsMergeAndMarksFollowTheirText() throws {
        let base = text("Buy milk tomorrow")
        let ours = text("Buy oat milk tomorrow")
        let confirmed = text("Buy milk tomorrow morning", [TextMark(start: 9, end: 17, kind: .b)])
        let merged = try #require(TextMerge.merge(base: base, ours: ours, confirmed: confirmed))
        #expect(merged.t == "Buy oat milk tomorrow morning")
        #expect(merged.m == [TextMark(start: 13, end: 21, kind: .b)])
        // Order doesn't matter for clean merges.
        #expect(TextMerge.merge(base: base, ours: confirmed, confirmed: ours)?.t == merged.t)
    }

    @Test func overlappingEditsDoNotMerge() {
        #expect(TextMerge.merge(base: text("Buy milk"), ours: text("Buy oat milk"), confirmed: text("Buy soy milk")) == nil)
        #expect(TextMerge.merge(base: text("Buy milk"), ours: text("Buy mlk"), confirmed: text("Buy mill")) != nil)
        #expect(TextMerge.merge(base: text("Buy milk"), ours: text("Buy milks"), confirmed: text("Buy milky")) == nil)
        #expect(TextMerge.merge(base: text("Buy milk"), ours: text("Buy milks"), confirmed: text("Buy silk"))?.t == "Buy silks")
        // The same edit on both sides is no conflict.
        #expect(TextMerge.merge(base: text("ab cd"), ours: text("aX cd!"), confirmed: text("aX cd")) == text("aX cd!"))
    }

    @Test func whenBothSidesChangeMarksOnTheSameTextTheConfirmedMarksWin() throws {
        let base = text("hello world", [TextMark(start: 0, end: 5, kind: .i)])
        let ours = text("hello world!", [TextMark(start: 0, end: 5, kind: .b)])
        let confirmed = text("hello world", [TextMark(start: 0, end: 5, kind: .u), TextMark(start: 6, end: 11, kind: .s)])
        let merged = try #require(TextMerge.merge(base: base, ours: ours, confirmed: confirmed))
        #expect(merged.t == "hello world!")
        #expect(merged.m == [TextMark(start: 0, end: 5, kind: .u), TextMark(start: 6, end: 11, kind: .s)])
        // Where only our side changed marks, ours stand.
        let mine = try #require(TextMerge.merge(base: base, ours: ours, confirmed: text("Oh hello world", [TextMark(start: 3, end: 8, kind: .i)])))
        #expect(mine.t == "Oh hello world!" && mine.m == [TextMark(start: 3, end: 8, kind: .b)])
    }

    @Test func mergeKeepsSurrogatePairsWhole() throws {
        let merged = try #require(TextMerge.merge(base: text("a😀b"), ours: text("a😀bc", [TextMark(start: 1, end: 3, kind: .b)]),
                                                  confirmed: text("Xa😀b")))
        #expect(merged.t == "Xa😀bc")
        #expect(merged.m == [TextMark(start: 2, end: 4, kind: .b)])
        #expect(TextMerge.merge(base: text("😀"), ours: text("😁"), confirmed: text("😃")) == nil)
    }

    @Test func diffHunksRebuildTheTarget() {
        var rng = SplitMix(state: 7)
        let alphabet = Array("abc ")
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0..<30, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            let b = (0..<Int.random(in: 0..<30, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            for limit in [1, 1_000] {
                var rebuilt: [Character] = [], position = 0
                for hunk in TextMerge.diff(a, b, limit: limit) {
                    rebuilt += a[position..<hunk.a.lowerBound] + b[hunk.b]
                    position = hunk.a.upperBound
                }
                rebuilt += a[position...]
                #expect(rebuilt == b)
            }
        }
    }

    /// Edits on disjoint halves of a text always merge, and the merge holds both.
    @Test func disjointRandomEditsAlwaysMerge() throws {
        var rng = SplitMix(state: 11)
        for _ in 0..<300 {
            let left = randomText(&rng, 12), right = randomText(&rng, 12)
            let base = left + "|" + right
            let ours = mutate(left, &rng) + "|" + right
            let confirmed = left + "|" + mutate(right, &rng)
            let merged = try #require(TextMerge.merge(base: text(base), ours: text(ours), confirmed: text(confirmed)))
            #expect(merged.t == ours.split(separator: "|", omittingEmptySubsequences: false)[0] + "|" + confirmed.split(separator: "|", omittingEmptySubsequences: false)[1])
        }
    }

    // MARK: Rebase and conflicts

    @Test func offlineTextEditsOnTwoDevicesMergeOnRebase() throws {
        var world = try World()
        let block = world.blocks[0]
        try world.a.edit([RecordChange(kind: .block, id: block, set: ["text": json(text("Buy oat milk tomorrow"))])], at: 2)
        try world.b.edit([RecordChange(kind: .block, id: block, set: ["text": json(text("Buy milk tomorrow morning"))])], at: 2)
        try world.host.sync(&world.a)
        try world.host.sync(&world.b)
        try world.host.sync(&world.a)
        #expect(world.a.confirmed == world.b.confirmed)
        #expect(world.a.current.text(of: block).t == "Buy oat milk tomorrow morning")
        #expect(world.a.current.blocks.count == 4, "no conflict copy")
    }

    @Test func overlappingEditsKeepTheConfirmedTextAndAddAConflictCopy() throws {
        var world = try World()
        let block = world.blocks[0], next = world.blocks[1]
        try world.a.edit([RecordChange(kind: .block, id: block, set: ["text": json(text("Buy soy milk tomorrow"))])], at: 2)
        try world.b.edit([RecordChange(kind: .block, id: block, set: ["text": json(text("Buy oat milk tomorrow")), "indent": .integer(1)])], at: 1_792_800_000_000)
        // B keeps typing in the block before it hears about A.
        try world.b.edit([RecordChange(kind: .block, id: block, set: ["text": json(text("Buy oat milk tomorrow!"))])], at: 1_792_800_000_001)
        try world.host.sync(&world.a)
        try world.host.sync(&world.b)
        try world.host.sync(&world.a)
        #expect(world.a.confirmed == world.b.confirmed)

        let state = world.b.confirmed
        #expect(state.text(of: block).t == "Buy soy milk tomorrow")
        #expect(state.block(block)?.indent == 1, "B's other keys still land on the original")
        let copies = state.blocks.keys.filter { state.block($0)?.conflict != nil }
        #expect(copies.count == 1)
        let copy = try #require(copies.first.flatMap { state.block($0) })
        #expect(copy.text.t == "Buy oat milk tomorrow!", "later typing follows into the copy")
        #expect(copy.conflict == BlockConflict(device: "Mac mini", at: 1_792_800_000_000))
        #expect(copy.page == world.root && !copy.trashed)
        let order = state.content(of: world.root).map(\.position.id)
        #expect(order.firstIndex(of: copies[0]) == order.firstIndex(of: block)! + 1)
        #expect(order.firstIndex(of: next) == order.firstIndex(of: block)! + 2)
    }

    @Test func conflictCopyFitsBetweenRecordsSharingAnOrderKey() throws {
        var state = SpaceState()
        let page = PageID(), first = BlockID(), second = BlockID()
        state.apply([try .page(page, PageRecord(order: key("a0"), created: 1)),
                     try .block(first, BlockRecord(page: page, order: key("a1"))),
                     try .block(second, BlockRecord(page: page, order: key("a1")))])
        let (low, high) = first < second ? (first, second) : (second, first)
        let (order, id) = SpaceReplica.placement(after: low, in: state)
        // Usually between the two; when no random id falls between them, after both.
        #expect(RecordPosition(order: key("a1"), id: low) < RecordPosition(order: order, id: id))
        _ = high
    }

    // MARK: Undo

    @Test func undoWritesInverseChangesThatSync() throws {
        var world = try World()
        let page = world.pages[0], block = world.blocks[3]
        let entry = try world.a.edit([
            RecordChange(kind: .page, id: page, set: ["title": .string("Renamed"), "props.score": .integer(3), "parent": .string(world.pages[1].rawValue)]),
            RecordChange(kind: .block, id: block, set: ["trashed": .bool(true)]),
        ], at: 2)
        try world.host.sync(&world.a)
        try world.host.sync(&world.b)
        #expect(world.b.current.page(page)?.title == "Renamed")

        let redo = try #require(try world.a.undo(entry, at: 3))
        try world.host.sync(&world.a)
        try world.host.sync(&world.b)
        let restored = try #require(world.b.current.page(page))
        #expect(restored.title == "Page 0" && restored.props["score"] == nil && restored.parent == world.root)
        #expect(world.b.current.block(block)?.trashed == false)

        try world.a.undo(redo, at: 4)
        try world.host.sync(&world.a)
        try world.host.sync(&world.b)
        #expect(world.b.current.page(page)?.title == "Renamed")
        #expect(world.a.confirmed == world.b.confirmed)
    }

    @Test func undoLeavesKeysAnotherDeviceChangedSince() throws {
        var world = try World()
        let page = world.pages[0]
        let entry = try world.a.edit([RecordChange(kind: .page, id: page, set: ["title": .string("Mine"), "icon": .string("🍎")])], at: 2)
        try world.host.sync(&world.a)
        try world.host.sync(&world.b)
        try world.b.edit([RecordChange(kind: .page, id: page, set: ["title": .string("Theirs")])], at: 3)
        try world.host.sync(&world.b)
        try world.host.sync(&world.a)

        try world.a.undo(entry, at: 4)
        #expect(world.a.current.page(page)?.title == "Theirs")
        #expect(world.a.current.page(page)?.icon == nil)
        #expect(try world.a.undo(entry, at: 5) == nil, "nothing left that still matches")
    }

    @Test func undoingACreationTrashesTheRecord() throws {
        var world = try World()
        let block = BlockID()
        let entry = try world.a.edit([try .block(block, BlockRecord(page: world.root, order: key("a9"), text: text("New")))], at: 2)
        try world.a.undo(entry, at: 3)
        #expect(world.a.current.block(block)?.trashed == true)
        #expect(world.a.current.text(of: block).t == "New", "history can restore it")
    }

    @Test func pendingOpsSurviveCoding() throws {
        var world = try World()
        try world.a.edit([RecordChange(kind: .block, id: world.blocks[0], set: ["text": json(text("x"))])], at: 2)
        let pending = world.a.pending
        #expect(try SpaceJSON.decode([PendingOp].self, from: SpaceJSON.encode(pending)) == pending)
        let reopened = SpaceReplica(device: world.a.device, label: "MacBook", confirmed: world.a.confirmed, pending: pending)
        #expect(reopened.current == world.a.current)
        #expect(pending[0].recs == [RecordRevision(id: world.blocks[0], base: 1)])
    }

    // MARK: Convergence

    /// Two replicas edit at random, offline and online, push stale ops, undo, and sync in random order.
    /// Once both have pushed everything, their confirmed states match and nothing is left pending.
    @Test(arguments: 0..<120)
    func randomEditsOnTwoReplicasConverge(seed: UInt64) throws {
        var rng = SplitMix(state: seed)
        var world = try World()
        var undo: [[UndoEntry]] = [[], []]
        for step in 0..<60 {
            let side = Int.random(in: 0...1, using: &rng)
            var replica = side == 0 ? world.a : world.b
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...4:
                undo[side].append(try randomEdit(&replica, world: world, at: Int64(step), &rng))
            case 5:
                if let entry = undo[side].popLast(), let redo = try replica.undo(entry, at: Int64(step)) { _ = redo }
            case 6:
                if let op = replica.pending.first { _ = world.host.push(op, from: replica.device) }
            case 7:
                for op in replica.pending { _ = world.host.push(op, from: replica.device) }
            default:
                try world.host.catchUp(&replica)
            }
            if side == 0 { world.a = replica } else { world.b = replica }
        }
        try world.host.sync(&world.a)
        try world.host.sync(&world.b)
        try world.host.sync(&world.a)

        #expect(world.a.pending.isEmpty && world.b.pending.isEmpty)
        #expect(world.a.confirmed == world.b.confirmed, "seed \(seed)")
        #expect(world.a.current == world.a.confirmed && world.b.current == world.b.confirmed)
        let state = world.a.confirmed
        for page in state.pages.keys {
            var hops = 0, current: PageID? = page
            while let id = current { current = state.parent(of: id); hops += 1; if hops > state.pages.count { break } }
            #expect(hops <= state.pages.count, "cycle through \(page)")
        }
        for id in state.blocks.keys { #expect(state.block(id) != nil, "block \(id) readable") }
    }
}

// MARK: Generators

private let letters = Array("ab c😀é")

private func randomText(_ rng: inout SplitMix, _ maxLength: Int) -> String {
    String((0..<Int.random(in: 0...maxLength, using: &rng)).map { _ in letters.randomElement(using: &rng)! })
}

/// One insert, delete or replace at scalar boundaries.
private func mutate(_ value: String, _ rng: inout SplitMix) -> String {
    var characters = Array(value)
    let start = Int.random(in: 0...characters.count, using: &rng)
    let end = Int.random(in: start...min(characters.count, start + 4), using: &rng)
    let insert = Array(randomText(&rng, 4))
    if start == end && insert.isEmpty { return value + "x" }
    characters.replaceSubrange(start..<end, with: insert)
    let result = String(characters)
    return result == value ? value + "x" : result
}

private func randomEdit(_ replica: inout SpaceReplica, world: World, at: Int64, _ rng: inout SplitMix) throws -> UndoEntry {
    let state = replica.current
    let blocks = state.blocks.keys.sorted()
    let pages = [world.root] + world.pages
    switch Int.random(in: 0..<8, using: &rng) {
    case 0...2:
        let block = blocks.randomElement(using: &rng)!
        var value = state.text(of: block)
        value.t = mutate(value.t, &rng)
        let scalars = value.t.unicodeScalars.map { $0.utf16.count }
        value.m = []
        if Bool.random(using: &rng), scalars.count > 1 {
            let a = Int.random(in: 0..<scalars.count - 1, using: &rng), b = Int.random(in: a + 1...scalars.count, using: &rng)
            value.m = [TextMark(start: scalars[..<a].reduce(0, +), end: scalars[..<b].reduce(0, +), kind: .b)]
        }
        return try replica.edit([RecordChange(kind: .block, id: block, set: ["text": json(value)])], at: at)
    case 3:
        let page = world.pages.randomElement(using: &rng)!
        let parent = pages.randomElement(using: &rng)!
        return try replica.edit([RecordChange(kind: .page, id: page, set: ["parent": .string(parent.rawValue)])], at: at)
    case 4:
        let page = pages.randomElement(using: &rng)!
        return try replica.edit([RecordChange(kind: .page, id: page, set: ["title": .string(randomText(&rng, 6)), "props.n": .integer(at)])], at: at)
    case 5:
        let positions = state.content(of: world.root).map(\.position)
        let index = Int.random(in: 0...positions.count, using: &rng)
        let lower = index > 0 ? positions[index - 1].order : nil
        let upper = index < positions.count ? positions[index].order : nil
        let order = try (try? OrderKey.between(lower, upper)) ?? OrderKey.between(lower, nil)
        return try replica.edit([try .block(BlockID(), BlockRecord(page: world.root, order: order, text: text(randomText(&rng, 8))))], at: at)
    default:
        let block = blocks.randomElement(using: &rng)!
        return try replica.edit([RecordChange(kind: .block, id: block, set: ["trashed": .bool(Bool.random(using: &rng))])], at: at)
    }
}
