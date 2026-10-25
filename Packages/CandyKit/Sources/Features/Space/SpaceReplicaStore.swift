import Foundation
import SpaceEngine
import SpaceModel

/// A page's live block or child page, in content order.
public enum SpaceContent: Equatable {
    case block(BlockID, BlockRecord)
    case page(PageID, PageRecord)
    public var id: RecordID { switch self { case .block(let id, _), .page(let id, _): id } }
    public var order: OrderKey { switch self { case .block(_, let r): r.order; case .page(_, let r): r.order } }
}

/// What the page editor needs beyond pages: blocks, a page's content, and edits that return undo entries.
@MainActor
public protocol SpaceDocumentStore: SpacePageStore {
    func block(_ id: BlockID) -> BlockRecord?
    func content(of page: PageID) -> [SpaceContent]
    /// Applies changes as one local edit. Returns the entry that undoes it, or nil when nothing changed.
    @discardableResult func edit(_ changes: [RecordChange], at: Int64) -> UndoEntry?
    /// Writes the entry's old values back as a new edit. Returns the redo entry.
    @discardableResult func undo(_ entry: UndoEntry, at: Int64) -> UndoEntry?
    /// The last local edit per page, for the "Edited" line.
    var edited: [PageID: Int64] { get }
    /// The records the last change touched, readable from an observer callback.
    var lastChanged: Set<RecordID> { get }
    /// The page's versions from the change log, newest first (docs/space.md section 9).
    func history(of page: PageID) async throws -> [SpaceVersion]
    /// The changes that put the page back to `version`, for the editor to commit as one undoable edit.
    func restoreChanges(_ version: SpaceVersion) -> [RecordChange]
    /// "This Mac" for this device's edits in history.
    func deviceLabel(_ device: DeviceID) -> String
}

public extension SpaceDocumentStore {
    @discardableResult func edit(_ changes: [RecordChange]) -> UndoEntry? { edit(changes, at: SpaceClock.now()) }
    @discardableResult func undo(_ entry: UndoEntry) -> UndoEntry? { undo(entry, at: SpaceClock.now()) }
}

/// Space's records on piece 4's replica (docs/space.md sections 3 and 9). Every write is a replica edit, so undo
/// writes inverse changes and sync can push the same pending ops later. The sidebar reads pages through
/// `SpacePageStore`; the page editor reads blocks and writes changes through `edit` and `undo`.
/// Nothing here reaches agents, threads or the Orchestrator.
@MainActor
public final class SpaceReplicaStore: SpaceDocumentStore {
    public private(set) var replica: SpaceReplica
    public private(set) var pages: [PageID: PageRecord] = [:]
    private var allPages: [PageID: PageRecord] = [:]
    private var blockCache: [BlockID: BlockRecord] = [:]
    private var blocksByPage: [PageID: Set<BlockID>] = [:]
    private var childrenByParent: [PageID: Set<PageID>] = [:]
    /// Deleted forever. ponytail: hidden for this run only, since records are never removed; purge them in the
    /// snapshot when the local copy lands.
    private var removed: Set<PageID> = []
    /// The last local edit per page, for the "Edited" line. ponytail: in memory, read it from the log once sync lands.
    public private(set) var edited: [PageID: Int64] = [:]
    /// The records the last change touched, readable from an observer callback.
    public private(set) var lastChanged: Set<RecordID> = []
    /// Runs after each local edit with the op it queued, so the local copy can persist it before it shows.
    public var onEdit: ((PendingOp) -> Void)?
    private var observers: [Int: @MainActor () -> Void] = [:]
    private var nextToken = 0

    public init(replica: SpaceReplica) {
        self.replica = replica
        reindex()
    }

    /// A store for this run only, seeded with `pages`.
    /// ponytail: a fixed device label; settings (piece 10) names the device before sync can make conflict copies.
    public convenience init(pages seed: [PageID: PageRecord] = [:], label: String = "This Mac") {
        self.init(replica: SpaceReplica(device: DeviceID(), label: label))
        if !seed.isEmpty { put(seed) }
        edited = [:]
    }

    // MARK: Reads

    public func block(_ id: BlockID) -> BlockRecord? { blockCache[id] }

    /// Every readable page, deleted ones included, for walking a subtree.
    var allPageRecords: [PageID: PageRecord] { allPages }

    /// A page's live blocks and child pages in content order: order key, then record id.
    public func content(of page: PageID) -> [SpaceContent] {
        var out: [SpaceContent] = []
        for id in blocksByPage[page] ?? [] { if let r = blockCache[id], !r.trashed { out.append(.block(id, r)) } }
        for id in childrenByParent[page] ?? [] { if let r = pages[id], !r.trashed { out.append(.page(id, r)) } }
        return out.sorted { RecordPosition(order: $0.order, id: $0.id) < RecordPosition(order: $1.order, id: $1.id) }
    }

    // MARK: Writes

    /// Applies changes as one local edit. Returns the entry that undoes it, or nil when nothing changed.
    @discardableResult
    public func edit(_ changes: [RecordChange], at: Int64) -> UndoEntry? {
        var merged: [RecordChange] = []
        for change in changes where !change.set.isEmpty {
            if let i = merged.firstIndex(where: { $0.id == change.id && $0.kind == change.kind }) {
                merged[i].set.merge(change.set) { $1 }
            } else { merged.append(change) }
        }
        guard !merged.isEmpty, let entry = try? replica.edit(merged, at: at) else { return nil }
        if let op = replica.pending.last { onEdit?(op) }
        touched(merged.map { ($0.kind, $0.id) }, at: at)
        return entry
    }

    /// Writes the entry's old values back as a new edit. Returns the redo entry.
    @discardableResult
    public func undo(_ entry: UndoEntry, at: Int64) -> UndoEntry? {
        let before = replica.pending.count
        guard let redo = try? replica.undo(entry, at: at) else { return nil }
        if replica.pending.count > before, let op = replica.pending.last {
            onEdit?(op)
            touched(op.payload.changes.map { ($0.kind, $0.id) }, at: at)
        }
        return redo
    }

    public func put(_ records: [PageID: PageRecord]) {
        var changes: [RecordChange] = []
        for (id, record) in records.sorted(by: { $0.key < $1.key }) {
            guard case .object(let new)? = try? JSONValue(encoding: record) else { continue }
            if let change = Self.diff(.page, id, old: replica.current.pages[id], new: new) { changes.append(change) }
        }
        edit(changes)
    }

    /// Sets only the keys that differ, so undo and merges touch just what changed.
    public static func diff(_ kind: RecordKind, _ id: RecordID, old: SpaceState.Object?, new: SpaceState.Object) -> RecordChange? {
        var set: [String: JSONValue] = [:]
        for (key, value) in new where old?[key] != value { set[key] = value }
        for key in (old ?? [:]).keys where new[key] == nil { set[key] = .null }
        return set.isEmpty ? nil : RecordChange(kind: kind, id: id, set: set)
    }

    public func remove(_ id: PageID) {
        guard allPages[id] != nil else { return }
        let gone = [id] + SpaceTree.descendants(of: id, in: allPages)
        removed.formUnion(gone)
        for p in gone { pages[p] = nil }
        lastChanged = Set(gone)
        notify()
    }

    // MARK: History

    /// Edits of this run sit in the replica as pending ops, so history replays them on the confirmed state.
    public func history(of page: PageID) async throws -> [SpaceVersion] {
        SpaceHistory.versions(of: page, base: replica.confirmed, ops: replica.pending.map { (replica.device, $0.payload) },
                              stretch: Self.historyStretch)
    }

    /// Shortens the 10-minute version stretch for on-screen checks: `-CWSpaceHistoryStretch 20` at launch, in seconds.
    static var historyStretch: Int64 {
        let seconds = UserDefaults.standard.integer(forKey: "CWSpaceHistoryStretch")
        return seconds > 0 ? Int64(seconds) * 1000 : SpaceHistory.stretch
    }

    public func restoreChanges(_ version: SpaceVersion) -> [RecordChange] { SpaceHistory.restore(version, in: replica.current) }

    public func deviceLabel(_ device: DeviceID) -> String { device == replica.device ? replica.label : "Another device" }

    public func observe(_ callback: @escaping @MainActor () -> Void) -> Int {
        nextToken += 1
        observers[nextToken] = callback
        return nextToken
    }

    public func removeObserver(_ token: Int) { observers[token] = nil }

    // MARK: Caches

    private func reindex() {
        allPages = [:]; pages = [:]; blockCache = [:]; blocksByPage = [:]; childrenByParent = [:]
        for id in replica.current.pages.keys { refreshPage(id) }
        for id in replica.current.blocks.keys { refreshBlock(id) }
    }

    private func touched(_ records: [(RecordKind, RecordID)], at: Int64) {
        var changed: Set<RecordID> = []
        for (kind, id) in records {
            changed.insert(id)
            if kind == .page {
                let oldParent = allPages[id]?.parent
                refreshPage(id)
                edited[id] = at
                for parent in [oldParent, allPages[id]?.parent] { if let parent { edited[parent] = at } }
            } else if kind == .block {
                refreshBlock(id)
                if let page = blockCache[id]?.page { edited[page] = at }
            }
        }
        lastChanged = changed
        notify()
    }

    private func refreshPage(_ id: PageID) {
        if let old = allPages[id]?.parent { childrenByParent[old]?.remove(id) }
        let record = replica.current.page(id)
        allPages[id] = record
        pages[id] = removed.contains(id) ? nil : record
        if let parent = record?.parent { childrenByParent[parent, default: []].insert(id) }
    }

    private func refreshBlock(_ id: BlockID) {
        if let old = blockCache[id]?.page { blocksByPage[old]?.remove(id) }
        let record = replica.current.block(id)
        blockCache[id] = record
        if let page = record?.page { blocksByPage[page, default: []].insert(id) }
    }

    private func notify() { for f in observers.values { f() } }
}
