import Foundation

/// The files panel's tree state (FileBrowserPanel.tsx, useDirectoryEntries.ts, @pierre/trees with
/// `density: "compact"`, `flattenEmptyDirectories: true`, `initialExpansion: "closed"`,
/// `fileTreeSearchMode: "hide-non-matches"`). Folders load on first expand and stay cached when
/// collapsed. The view asks for `rows` and reports clicks; the owner loads what `load` names.
public struct FileTreeModel: Sendable {
    public struct Row: Equatable, Sendable {
        /// The entry the row acts on. For a flattened chain (`a / b`) the deepest folder.
        public var path: String
        /// `a / b` for a flattened chain.
        public var label: String
        public var depth: Int
        public var isDirectory: Bool
        public var isExpanded: Bool
        public var ignored: Bool
        public var isLoading: Bool
        public var isSearchMatch: Bool
    }

    /// Loaded folders: path ("" is the root) to its direct children.
    public private(set) var directories: [String: [ProjectEntry]] = [:]
    public private(set) var expanded: Set<String> = []
    public var loading: Set<String> = []
    /// Path search results while the search field has text (`useProjectPathSearch`).
    public private(set) var search: (query: String, entries: [ProjectEntry])?

    public init() {}

    public var ready: Bool { directories[""] != nil }

    /// Stores a folder's listing; only direct children count (useDirectoryEntries.ts:56-63).
    public mutating func setChildren(_ entries: [ProjectEntry], of directory: String) {
        directories[directory] = Self.sorted(entries.filter { $0.parent == directory })
    }

    public mutating func setSearch(_ query: String, entries: [ProjectEntry]?) {
        search = entries.map { (query, $0) }
    }

    /// Pierre's default order: folders first, then names compared case-insensitively with digit
    /// runs as numbers (`Lt`/`It` in the trees bundle).
    static func sorted(_ entries: [ProjectEntry]) -> [ProjectEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let r = naturalCompare(a.name, b.name)
            return r == 0 ? a.name < b.name : r < 0
        }
    }

    static func naturalCompare(_ a: String, _ b: String) -> Int {
        func tokens(_ s: String) -> [Any] {
            var out: [Any] = [], text = "", number: Int? = nil
            for ch in s.lowercased() {
                if let d = ch.wholeNumberValue, ch.isASCII {
                    if !text.isEmpty { out.append(text); text = "" }
                    number = (number ?? 0) * 10 + d
                } else {
                    if let n = number { out.append(n); number = nil }
                    text.append(ch)
                }
            }
            if let n = number { out.append(n) }
            if !text.isEmpty || out.isEmpty { out.append(text) }
            return out
        }
        let x = tokens(a), y = tokens(b)
        for i in 0..<min(x.count, y.count) {
            if let p = x[i] as? Int, let q = y[i] as? Int { if p != q { return p < q ? -1 : 1 }; continue }
            let p = "\(x[i])", q = "\(y[i])"
            if p != q { return p < q ? -1 : 1 }
        }
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
        let la = a.lowercased(), lb = b.lowercased()
        return la == lb ? 0 : la < lb ? -1 : 1
    }

    // MARK: Expansion

    /// Expands or collapses a folder. Returns the folder to load when it has never loaded.
    public mutating func toggle(_ path: String) -> String? {
        if expanded.contains(path) { expanded.remove(path); return nil }
        expanded.insert(path)
        return directories[path] == nil ? path : nil
    }

    /// Opens every ancestor of `path` (a reveal from the picker or a chat link). Returns the
    /// ancestors still to load, outermost first.
    public mutating func reveal(_ path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        var need: [String] = []
        if directories[""] == nil { need.append("") }
        for i in 0..<max(0, parts.count - 1) {
            let ancestor = parts[...i].joined(separator: "/")
            expanded.insert(ancestor)
            if directories[ancestor] == nil { need.append(ancestor) }
        }
        return need
    }

    /// Every loaded folder (`directoryPaths`).
    public var directoryPaths: [String] {
        var out: [String] = []
        func visit(_ dir: String) {
            for e in directories[dir] ?? [] where e.isDirectory {
                out.append(e.path)
                visit(e.path)
            }
        }
        visit("")
        return out
    }

    /// `areAllDirectoriesExpanded`.
    public var allExpanded: Bool {
        let dirs = directoryPaths
        return !dirs.isEmpty && dirs.allSatisfy(expanded.contains)
    }

    /// `setAllDirectoriesExpanded`: returns folders that now need a listing.
    public mutating func setAllExpanded(_ value: Bool) -> [String] {
        let dirs = directoryPaths
        if value { expanded.formUnion(dirs) } else { expanded.subtract(dirs) }
        return value ? dirs.filter { directories[$0] == nil } : []
    }

    // MARK: Rows

    public var rows: [Row] {
        if let search, !search.query.trimmingCharacters(in: .whitespaces).isEmpty { return searchRows(search.entries) }
        var out: [Row] = []
        func visit(_ dir: String, depth: Int) {
            for entry in directories[dir] ?? [] {
                if entry.isDirectory {
                    // `flattenEmptyDirectories`: a folder whose only loaded child is a folder shares its row.
                    var chain = [entry]
                    while let only = directories[chain.last!.path], only.count == 1, only[0].isDirectory { chain.append(only[0]) }
                    let last = chain.last!
                    let open = expanded.contains(last.path)
                    out.append(Row(path: last.path, label: chain.map(\.name).joined(separator: " / "), depth: depth,
                                   isDirectory: true, isExpanded: open, ignored: last.ignored,
                                   isLoading: open && loading.contains(last.path), isSearchMatch: false))
                    if open { visit(last.path, depth: depth + 1) }
                } else {
                    out.append(Row(path: entry.path, label: entry.name, depth: depth, isDirectory: false, isExpanded: false,
                                   ignored: entry.ignored, isLoading: false, isSearchMatch: false))
                }
            }
        }
        visit("", depth: 0)
        return out
    }

    /// `hide-non-matches`: the loaded tree plus the search results and their folders, only the
    /// branches that lead to a match, all open (FileBrowserPanel.tsx:119-132).
    private func searchRows(_ results: [ProjectEntry]) -> [Row] {
        var all: [String: ProjectEntry] = [:]
        for list in directories.values { for e in list { all[e.path] = e } }
        var matches = Set<String>()
        for e in results {
            all[e.path] = all[e.path] ?? e
            matches.insert(e.path)
            let parts = e.path.split(separator: "/").map(String.init)
            for i in 0..<max(0, parts.count - 1) {
                let p = parts[...i].joined(separator: "/")
                if all[p] == nil { all[p] = ProjectEntry(path: p, isDirectory: true) }
            }
        }
        var keep = Set<String>()
        for m in matches {
            keep.insert(m)
            var p = all[m]?.parent ?? ""
            while !p.isEmpty { keep.insert(p); p = all[p]?.parent ?? "" }
        }
        var children: [String: [ProjectEntry]] = [:]
        for e in all.values where keep.contains(e.path) { children[e.parent, default: []].append(e) }
        var out: [Row] = []
        func visit(_ dir: String, depth: Int) {
            for e in Self.sorted(children[dir] ?? []) {
                out.append(Row(path: e.path, label: e.name, depth: depth, isDirectory: e.isDirectory, isExpanded: e.isDirectory,
                               ignored: e.ignored, isLoading: false, isSearchMatch: matches.contains(e.path)))
                if e.isDirectory { visit(e.path, depth: depth + 1) }
            }
        }
        visit("", depth: 0)
        return out
    }

    /// The kind of a known path, nil when not loaded (`entryKinds`).
    public func isDirectory(_ path: String) -> Bool? {
        let parent = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        return directories[parent]?.first { $0.path == path }?.isDirectory
    }
}
