import Foundation
import SpaceEngine
import SpaceModel

/// Where Space's pages live. The sidebar and page tabs share this contract with the encrypted local store,
/// tests and previews. Sync can join the same path later (piece 7 of docs/space.md). Space data never
/// leaves the app through it: no agent, thread or Orchestrator surface reads it.
@MainActor
public protocol SpacePageStore: AnyObject {
    var pages: [PageID: PageRecord] { get }
    /// Writes several records as one change.
    func put(_ records: [PageID: PageRecord])
    /// Delete forever: the page and every page under it leave the store. History keeps their old text.
    func remove(_ id: PageID)
    /// Calls back after every change. Returns a token for `removeObserver`.
    func observe(_ callback: @escaping @MainActor () -> Void) -> Int
    func removeObserver(_ token: Int)
}

/// A store for isolated tests and previews. Pages live for this run only.
@MainActor
public final class InMemorySpacePageStore: SpacePageStore {
    public private(set) var pages: [PageID: PageRecord]
    private var observers: [Int: @MainActor () -> Void] = [:]
    private var nextToken = 0

    public init(pages: [PageID: PageRecord] = [:]) { self.pages = pages }

    public func put(_ records: [PageID: PageRecord]) {
        guard !records.isEmpty else { return }
        pages.merge(records) { $1 }
        notify()
    }

    public func remove(_ id: PageID) {
        guard pages[id] != nil else { return }
        for p in [id] + SpaceTree.descendants(of: id, in: pages) { pages[p] = nil }
        notify()
    }

    public func observe(_ callback: @escaping @MainActor () -> Void) -> Int {
        nextToken += 1
        observers[nextToken] = callback
        return nextToken
    }

    public func removeObserver(_ token: Int) { observers[token] = nil }

    private func notify() { for f in observers.values { f() } }
}

/// One visible row of the page tree.
public struct SpaceTreeRow: Equatable {
    public var id: PageID
    public var title: String
    public var depth: Int
    public var hasChildren: Bool
    public var expanded: Bool
    /// False for an ancestor that shows only because a descendant matches the search.
    public var matches = true
}

/// The page tree's rules (docs/space.md "Space mode"), as pure functions over the store's records.
public enum SpaceTree {
    /// Children in the tree: not trashed, and only under a parent shown in Page view, so a board's cards stay out.
    public static func children(of parent: PageID?, in pages: [PageID: PageRecord]) -> [PageID] {
        if let parent, pages[parent]?.view != .page { return [] }
        return pages.filter { $0.value.parent == parent && !$0.value.trashed }
            .sorted { RecordPosition(order: $0.value.order, id: $0.key) < RecordPosition(order: $1.value.order, id: $1.key) }
            .map(\.key)
    }

    /// The rows to draw. With a query, only matching pages and their ancestors show, all expanded.
    public static func rows(_ pages: [PageID: PageRecord], expanded: Set<PageID>, query: String = "") -> [SpaceTreeRow] {
        let words = SpaceSearch.words(query)
        var keep: Set<PageID>?
        if !words.isEmpty {
            var set = Set<PageID>()
            for id in reachable(pages) where SpaceSearch.matches(pages[id]!.title, words) {
                var cur: PageID? = id
                while let c = cur, set.insert(c).inserted { cur = pages[c]?.parent }
            }
            keep = set
        }
        var out: [SpaceTreeRow] = []
        func walk(_ parent: PageID?, _ depth: Int) {
            for id in children(of: parent, in: pages) where keep?.contains(id) ?? true {
                let kids = children(of: id, in: pages)
                let open = keep != nil || expanded.contains(id)
                let matches = keep == nil || SpaceSearch.matches(pages[id]!.title, words)
                out.append(SpaceTreeRow(id: id, title: pages[id]!.title, depth: depth, hasChildren: !kids.isEmpty, expanded: open && !kids.isEmpty, matches: matches))
                if open && depth < 64 { walk(id, depth + 1) }
            }
        }
        walk(nil, 0)
        return out
    }

    /// Every page the tree can show, at any depth.
    static func reachable(_ pages: [PageID: PageRecord]) -> [PageID] {
        var out: [PageID] = [], queue: [PageID?] = [nil], seen = Set<PageID>()
        while !queue.isEmpty {
            for id in children(of: queue.removeFirst(), in: pages) where seen.insert(id).inserted {
                out.append(id)
                queue.append(id)
            }
        }
        return out
    }

    /// Every page under `id` at any depth, trashed or not.
    public static func descendants(of id: PageID, in pages: [PageID: PageRecord]) -> [PageID] {
        var byParent: [PageID: [PageID]] = [:]
        for (child, r) in pages { if let p = r.parent { byParent[p, default: []].append(child) } }
        var out: [PageID] = [], queue = [id], seen: Set<PageID> = [id]
        while let next = queue.popLast() {
            for child in byParent[next] ?? [] where seen.insert(child).inserted { out.append(child); queue.append(child) }
        }
        return out
    }

    /// True when `id` is `ancestor` or sits anywhere under it.
    public static func isDescendant(_ id: PageID, of ancestor: PageID, in pages: [PageID: PageRecord]) -> Bool {
        var cur: PageID? = id, steps = 0
        while let c = cur, steps < 10_000 {
            if c == ancestor { return true }
            cur = pages[c]?.parent
            steps += 1
        }
        return false
    }

    /// The titles from the top down to `id`'s parent, for a breadcrumb.
    public static func ancestors(of id: PageID, in pages: [PageID: PageRecord]) -> [PageID] {
        var out: [PageID] = [], cur = pages[id]?.parent
        while let c = cur, !out.contains(c) { out.insert(c, at: 0); cur = pages[c]?.parent }
        return out
    }

    /// An order key that puts a page before `before` among `parent`'s children, or last for nil. `moving` is left
    /// out of the siblings, so a page dropped next to itself stays valid.
    static func order(in parent: PageID?, before: PageID?, moving: PageID?, _ pages: [PageID: PageRecord]) -> OrderKey {
        let siblings = pages.filter { $0.value.parent == parent && $0.key != moving }
            .map { RecordPosition(order: $0.value.order, id: $0.key) }.sorted()
        let i = before.flatMap { b in siblings.firstIndex { $0.id == b } } ?? siblings.count
        let lower = i > 0 ? siblings[i - 1].order : nil
        let upper = i < siblings.count ? siblings[i].order : nil
        // Equal keys only happen between records from other clients; the id breaks the tie, so the lower key works.
        return (try? OrderKey.between(lower, upper == lower ? nil : upper)) ?? (try! OrderKey.between(lower, nil))
    }
}

/// Title search: case and diacritic insensitive word prefixes, and every word must match (docs/space.md "Search").
public enum SpaceSearch {
    public static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    public static func words(_ query: String) -> [String] {
        fold(query).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    public static func matches(_ title: String, _ words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let titleWords = fold(title).split { !$0.isLetter && !$0.isNumber }
        return words.allSatisfy { w in titleWords.contains { $0.hasPrefix(w) } }
    }
}

/// The tree's edits, each one `put` on the store.
public extension SpacePageStore {
    /// A new empty page at the end of `parent`'s children.
    @discardableResult
    func createPage(in parent: PageID? = nil, title: String = "", now: Int64 = SpaceClock.now()) -> PageID {
        let id = PageID()
        put([id: PageRecord(parent: parent, order: SpaceTree.order(in: parent, before: nil, moving: nil, pages), title: title, created: now)])
        return id
    }

    /// Moves a page under `parent`, before the sibling `before` or last. Refuses to put a page inside itself or under
    /// a page whose children the tree hides.
    @discardableResult
    func move(_ id: PageID, to parent: PageID?, before: PageID?) -> Bool {
        guard var record = pages[id] else { return false }
        if let parent {
            guard pages[parent]?.view == .page, !SpaceTree.isDescendant(parent, of: id, in: pages) else { return false }
        }
        if before == id { return true }
        record.order = SpaceTree.order(in: parent, before: before, moving: id, pages)
        record.parent = parent
        put([id: record])
        return true
    }

    func rename(_ id: PageID, _ title: String) {
        guard var record = pages[id], record.title != title else { return }
        record.title = title
        put([id: record])
    }

    /// A copy right after the page, with its child pages copied too. With blocks, each copied page's live blocks get
    /// fresh ids under the copy, blob references kept, all in the same single edit.
    @discardableResult
    func duplicate(_ id: PageID, now: Int64 = SpaceClock.now()) -> PageID? {
        guard let source = pages[id] else { return nil }
        let document = self as? SpaceDocumentStore
        let next = SpaceTree.children(of: source.parent, in: pages).drop { $0 != id }.dropFirst().first
        var out: [PageID: PageRecord] = [:]
        var blocks: [BlockID: BlockRecord] = [:]
        func copy(_ from: PageID, parent: PageID?, order: OrderKey) -> PageID {
            let new = PageID()
            var r = pages[from]!
            r.parent = parent
            r.order = order
            r.created = now
            out[new] = r
            for case .block(_, var block) in document?.content(of: from) ?? [] {
                block.page = new
                blocks[BlockID()] = block
            }
            for child in pages.filter({ $0.value.parent == from && !$0.value.trashed }).map(\.key) {
                _ = copy(child, parent: new, order: pages[child]!.order)
            }
            return new
        }
        let copyId = copy(id, parent: source.parent, order: SpaceTree.order(in: source.parent, before: next, moving: nil, pages))
        out[copyId]!.title = source.title.isEmpty ? "" : source.title + " copy"
        guard let document else { put(out); return copyId }
        let changes = out.sorted { $0.key < $1.key }.compactMap { try? RecordChange.page($0.key, $0.value) }
            + blocks.sorted { $0.key < $1.key }.compactMap { try? RecordChange.block($0.key, $0.value) }
        document.edit(changes, at: now)
        return copyId
    }

    func trash(_ id: PageID, now: Int64 = SpaceClock.now()) {
        guard var record = pages[id], !record.trashed else { return }
        record.trashed = true
        record.trashedAt = now
        put([id: record])
    }

    /// Back into the tree where it was, or at the top when its parent is gone or trashed.
    func restore(_ id: PageID) {
        guard var record = pages[id], record.trashed else { return }
        record.trashed = false
        record.trashedAt = nil
        if let p = record.parent, pages[p] == nil || pages[p]!.trashed || SpaceTree.ancestors(of: p, in: pages).contains(where: { pages[$0]!.trashed }) {
            record.parent = nil
            record.order = SpaceTree.order(in: nil, before: nil, moving: id, pages)
        }
        put([id: record])
    }

    /// Trashed pages, newest first.
    var trashed: [PageID] {
        pages.filter(\.value.trashed).sorted { ($0.value.trashedAt ?? 0, $0.key.rawValue) > ($1.value.trashedAt ?? 0, $1.key.rawValue) }.map(\.key)
    }

    /// Whether the page shows anywhere: in the tree, or as an item of a page in another view.
    func isLive(_ id: PageID) -> Bool {
        guard let r = pages[id], !r.trashed else { return false }
        return !SpaceTree.ancestors(of: id, in: pages).contains { pages[$0]?.trashed ?? true }
    }
}

public enum SpaceClock {
    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
