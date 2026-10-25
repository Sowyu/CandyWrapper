import Foundation
import SpaceModel

/// One entry of a page's history: the page as it stood after a stretch of edits from one device
/// (docs/space.md section 9).
public struct SpaceVersion: Hashable, Sendable {
    /// The last change in the stretch counts from 1 in the replayed log, so it names the version.
    public var index: Int
    /// The device clock of the stretch's first and last edits.
    public var started: Int64
    public var at: Int64
    public var device: DeviceID
    public var edits: Int
    /// The page record at this point, nil if the page didn't exist yet.
    public var page: SpaceState.Object?
    /// Every block whose `page` was this page at this point, trashed ones included.
    public var blocks: [BlockID: SpaceState.Object]

    /// The page as it was, for a read-only preview: just this page and its blocks.
    public var state: SpaceState {
        SpaceState(pages: page.map { [pageID: $0] } ?? [:], blocks: blocks)
    }
    public let pageID: PageID
}

/// Page history from the change log, and the change that restores a version.
public enum SpaceHistory {
    /// One version per device per 10-minute stretch, counted from the stretch's first edit.
    public static let stretch: Int64 = 10 * 60 * 1000

    /// Replays `ops`, oldest first, on top of `base` and returns the page's versions, newest first.
    /// Each op touching the page or one of its blocks joins the open stretch or starts a new one.
    /// ponytail: each version keeps a copy of the page's blocks, about versions × blocks objects; keep only
    /// the replay index and rebuild on pick if a page's history passes 50 MB.
    public static func versions(of page: PageID, base: SpaceState, ops: [(device: DeviceID, payload: OpPayload)],
                                stretch: Int64 = SpaceHistory.stretch) -> [SpaceVersion] {
        var state = base
        let pageRaw = JSONValue.string(page.rawValue)
        // Blocks that ever belonged to the page, so a snapshot reads only those.
        var mine = Set(base.blocks.compactMap { $0.value["page"] == pageRaw ? $0.key : nil })
        var out: [SpaceVersion] = []
        var open: SpaceVersion?

        func snapshot(_ v: inout SpaceVersion) {
            v.page = state.pages[page]
            v.blocks = [:]
            for id in mine { if let b = state.blocks[id], b["page"] == pageRaw { v.blocks[id] = b } }
        }

        for (i, op) in ops.enumerated() {
            // Every change is checked, so each block moving in joins `mine` even after an earlier match.
            var touches = false
            for change in op.payload.changes {
                switch change.kind {
                case .page: if change.id == page { touches = true }
                case .block:
                    if change.set["page"] == pageRaw { mine.insert(change.id); touches = true }
                    else if mine.contains(change.id) && state.blocks[change.id]?["page"] == pageRaw { touches = true }
                default: break
                }
            }
            if touches, var v = open, (v.device != op.device || op.payload.at - v.started >= stretch) {
                snapshot(&v)
                out.append(v)
                open = nil
            }
            state.apply(op.payload.changes)
            guard touches else { continue }
            if open == nil {
                open = SpaceVersion(index: i + 1, started: op.payload.at, at: op.payload.at, device: op.device,
                                    edits: 0, page: nil, blocks: [:], pageID: page)
            }
            open!.index = i + 1
            open!.at = op.payload.at
            open!.edits += 1
        }
        if var v = open { snapshot(&v); out.append(v) }
        return out.reversed()
    }

    /// The changes that put the page back to `version` in `current`, as one edit: every block the version had takes
    /// its values back, trashed or not, blocks added since go to Trash, and the title and icon, emoji or image, return. Child pages
    /// keep their place, since history covers the page's own text. Empty when nothing differs.
    public static func restore(_ version: SpaceVersion, in current: SpaceState) -> [RecordChange] {
        let page = version.pageID
        let pageRaw = JSONValue.string(page.rawValue)
        var changes: [RecordChange] = []
        if let old = version.page {
            var set: [String: JSONValue] = [:]
            for key in ["title", "icon", "iconImage"] where current.pages[page]?[key] != old[key] { set[key] = old[key] ?? .null }
            if !set.isEmpty { changes.append(RecordChange(kind: .page, id: page, set: set)) }
        }
        for (id, old) in version.blocks.sorted(by: { $0.key < $1.key }) {
            if let change = diff(.block, id, from: current.blocks[id], to: old) { changes.append(change) }
        }
        let added = current.blocks.filter { $0.value["page"] == pageRaw && version.blocks[$0.key] == nil && $0.value["trashed"] != .bool(true) }
        for id in added.keys.sorted() {
            changes.append(RecordChange(kind: .block, id: id, set: ["trashed": .bool(true)]))
        }
        return changes
    }

    /// Sets only the keys that differ; keys `to` lacks are removed.
    public static func diff(_ kind: RecordKind, _ id: RecordID, from old: SpaceState.Object?, to new: SpaceState.Object) -> RecordChange? {
        var set: [String: JSONValue] = [:]
        for (key, value) in new where old?[key] != value { set[key] = value }
        for key in (old ?? [:]).keys where new[key] == nil { set[key] = .null }
        return set.isEmpty ? nil : RecordChange(kind: kind, id: id, set: set)
    }
}
