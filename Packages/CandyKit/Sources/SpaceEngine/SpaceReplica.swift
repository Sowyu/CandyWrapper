import Foundation
import SpaceModel

/// The text a pending change edited from: the block's confirmed rev, and its text on screen at the time.
public struct TextBase: Codable, Hashable, Sendable {
    public var rev: Int64
    public var text: RichText
    public init(rev: Int64, text: RichText) { self.rev = rev; self.text = text }
}

/// A local op the Space machine hasn't confirmed yet. Codable for `pending.cws`.
public struct PendingOp: Codable, Hashable, Sendable {
    public var op: OpID
    public var payload: OpPayload
    /// Keyed by block id, one per change that sets `text`.
    public var bases: [String: TextBase]

    public init(op: OpID, payload: OpPayload, bases: [String: TextBase]) {
        self.op = op; self.payload = payload; self.bases = bases
    }

    /// The frame's `recs`: each record once, in change order. Text changes carry their base rev,
    /// everything else null, since per-key sets merge on their own.
    public var recs: [RecordRevision] {
        var seen: Set<RecordID> = []
        return payload.changes.compactMap { change in
            seen.insert(change.id).inserted ? RecordRevision(id: change.id, base: bases[change.id.rawValue]?.rev) : nil
        }
    }
}

/// One device's copy: the confirmed state from frames in seq order, with its pending ops on top
/// (docs/space.md, "Offline edits and two devices"). The screen shows `current`.
public struct SpaceReplica: Hashable, Sendable {
    public let device: DeviceID
    /// The device name a conflict copy shows, as in "Your edit on <device> at 10:42".
    public var label: String
    public private(set) var confirmed: SpaceState
    public private(set) var pending: [PendingOp]
    public private(set) var current: SpaceState

    public init(device: DeviceID, label: String, confirmed: SpaceState = SpaceState(), pending: [PendingOp] = []) {
        self.device = device; self.label = label; self.confirmed = confirmed; self.pending = pending
        current = confirmed
        rebase()
    }

    /// Applies a local edit at once and queues it. Each record appears in at most one change.
    /// Returns the entry that undoes it.
    @discardableResult
    public mutating func edit(_ changes: [RecordChange], at: Int64, op: OpID = OpID()) throws -> UndoEntry {
        var seen: Set<RecordID> = []
        for change in changes where !seen.insert(change.id).inserted { throw ApplyError.repeatedRecord(change.id) }
        var bases: [String: TextBase] = [:]
        for change in changes where change.kind == .block && change.set["text"] != nil {
            bases[change.id.rawValue] = TextBase(rev: confirmed.revs[change.id] ?? 0, text: current.text(of: change.id))
        }
        let before = current
        current.apply(changes)
        pending.append(PendingOp(op: op, payload: OpPayload(at: at, changes: changes), bases: bases))
        return UndoEntry(changes, before: before, after: current)
    }

    /// Applies confirmed frames in seq order, drops the pending ops they confirm, then rebases the rest.
    /// Frames this copy already has are skipped. A gap throws and leaves the copy unchanged.
    public mutating func receive(_ frames: [(frame: LogFrame, payload: OpPayload)]) throws {
        var next = confirmed
        var done: Set<OpID> = []
        for (frame, payload) in frames where frame.seq > next.seq {
            try next.apply(frame, payload)
            done.insert(frame.op)
        }
        confirmed = next
        pending.removeAll { done.contains($0.op) }
        rebase()
    }

    /// Replays pending ops on the confirmed state. A text change whose block moved past its base rev
    /// gets a three-way merge, and overlapping edits become a conflict copy after the block. Later
    /// pending text for that block follows into the copy.
    mutating func rebase() {
        var working = confirmed
        var redirects: [BlockID: BlockID] = [:]
        var rebased: [PendingOp] = []
        for var op in pending {
            if !redirects.isEmpty { redirect(&op, redirects) }
            var copies: [RecordChange] = []
            for index in op.payload.changes.indices {
                let change = op.payload.changes[index]
                guard change.kind == .block, let value = change.set["text"], let base = op.bases[change.id.rawValue] else { continue }
                let rev = confirmed.revs[change.id] ?? 0
                guard rev != base.rev else { continue }
                let confirmedText = working.text(of: change.id)
                guard let ours = try? value.decoded(RichText.self) else {
                    op.bases[change.id.rawValue] = TextBase(rev: rev, text: confirmedText)
                    continue
                }
                if let merged = TextMerge.merge(base: base.text, ours: ours, confirmed: confirmedText) {
                    op.payload.changes[index].set["text"] = try? JSONValue(encoding: merged)
                    op.bases[change.id.rawValue] = TextBase(rev: rev, text: confirmedText)
                } else {
                    let copy = conflictCopy(of: change.id, text: ours, at: op.payload.at, in: working)
                    copies.append(copy)
                    op.payload.changes[index].set["text"] = nil
                    op.bases[change.id.rawValue] = nil
                    op.bases[copy.id.rawValue] = TextBase(rev: 0, text: RichText())
                    redirects[change.id] = copy.id
                }
            }
            op.payload.changes.removeAll { $0.kind == .block && $0.set.isEmpty && working.blocks[$0.id] != nil }
            op.payload.changes += copies
            guard !op.payload.changes.isEmpty else { continue }
            working.apply(op.payload.changes)
            rebased.append(op)
        }
        pending = rebased
        current = working
    }

    /// Moves `text` sets on redirected blocks to their conflict copies, keeping their base text.
    func redirect(_ op: inout PendingOp, _ redirects: [BlockID: BlockID]) {
        var moved: [RecordChange] = []
        for index in op.payload.changes.indices {
            let change = op.payload.changes[index]
            guard change.kind == .block, let copy = redirects[change.id], let text = change.set["text"] else { continue }
            op.payload.changes[index].set["text"] = nil
            moved.append(RecordChange(kind: .block, id: copy, set: ["text": text]))
            if let base = op.bases.removeValue(forKey: change.id.rawValue) {
                op.bases[copy.rawValue] = TextBase(rev: 0, text: base.text)
            }
        }
        op.payload.changes.removeAll { $0.kind == .block && $0.set.isEmpty }
        op.payload.changes += moved
    }

    /// A new block right after the original with the device's text and `conflict` set.
    func conflictCopy(of block: BlockID, text: RichText, at: Int64, in state: SpaceState) -> RecordChange {
        var record = state.blocks[block] ?? [:]
        record["text"] = try? JSONValue(encoding: text)
        record["conflict"] = try? JSONValue(encoding: BlockConflict(device: label, at: at))
        record["trashed"] = .bool(false)
        let (order, id) = Self.placement(after: block, in: state)
        record["order"] = .string(order.rawValue)
        return RecordChange(kind: .block, id: id, set: record)
    }

    /// An order key and id that sort right after `block` among its page's content.
    static func placement(after block: BlockID, in state: SpaceState) -> (OrderKey, BlockID) {
        guard let record = state.blocks[block], let order = SpaceState.order(record),
              case .string(let raw)? = record["page"], let page = try? PageID(raw) else {
            return ((try? OrderKey.between(nil, nil))!, BlockID())
        }
        let me = RecordPosition(order: order, id: block)
        let next = state.content(of: page).map(\.position).first { me < $0 }
        if let key = try? OrderKey.between(order, next?.order) { return (key, BlockID()) }
        // The next record shares this order key, so only an id between the two places the copy.
        for _ in 0..<64 {
            let id = BlockID()
            if me < RecordPosition(order: order, id: id), next.map({ RecordPosition(order: order, id: id) < $0 }) ?? true { return (order, id) }
        }
        return ((try? OrderKey.between(order, nil))!, BlockID())
    }

    /// Writes the entry's old values back as a new local edit, skipping every key another change
    /// has touched since. Returns the redo entry, or nil when nothing was left to undo.
    @discardableResult
    public mutating func undo(_ entry: UndoEntry, at: Int64) throws -> UndoEntry? {
        var changes: [RecordChange] = []
        for slot in entry.slots where current.value(slot.kind, slot.id, slot.key) == slot.after {
            if let index = changes.firstIndex(where: { $0.id == slot.id }) {
                changes[index].set[slot.key] = slot.restore ?? .null
            } else {
                changes.append(RecordChange(kind: slot.kind, id: slot.id, set: [slot.key: slot.restore ?? .null]))
            }
        }
        return changes.isEmpty ? nil : try edit(changes, at: at)
    }
}

/// What undoing one edit writes back (docs/space.md section 9). Undoing a record's creation trashes it.
public struct UndoEntry: Hashable, Sendable {
    struct Slot: Hashable, Sendable {
        var kind: RecordKind
        var id: RecordID
        var key: String
        /// The value undo writes, nil to remove the key.
        var restore: JSONValue?
        /// The value the edit left. Undo skips the key once it reads differently.
        var after: JSONValue?
    }
    var slots: [Slot] = []

    init(_ changes: [RecordChange], before: SpaceState, after: SpaceState) {
        for change in changes {
            if !before.exists(change.kind, change.id) {
                slots.append(Slot(kind: change.kind, id: change.id, key: "trashed", restore: .bool(true),
                                  after: after.value(change.kind, change.id, "trashed")))
                continue
            }
            for key in change.set.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                slots.append(Slot(kind: change.kind, id: change.id, key: key,
                                  restore: before.value(change.kind, change.id, key), after: after.value(change.kind, change.id, key)))
            }
        }
    }
}
