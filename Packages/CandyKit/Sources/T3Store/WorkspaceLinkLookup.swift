import Foundation

/// Finds the file a chat link names when the agent cited it by basename, relative to a package, or from another
/// project (`workspaceBasenameLookup.ts` in client-runtime at 4928, #33943 and #35036). Pure: the app runs the
/// `projects.searchEntries` calls and passes their entries in.
public enum WorkspaceLinkLookup {
    public static let searchLimit = 25

    public struct Entry: Sendable, Equatable {
        public var path: String
        public var isFile: Bool
        public init(path: String, isFile: Bool) { self.path = path; self.isFile = isFile }
    }

    private static func basename(_ path: Substring) -> Substring {
        path.lastIndex(where: { $0 == "/" || $0 == "\\" }).map { path[path.index(after: $0)...] } ?? path
    }
    private static func isWindowsAbsolute(_ path: String) -> Bool {
        path.range(of: #"^(?:[A-Za-z]:[\\/]|\\\\)"#, options: .regularExpression) != nil
    }
    private static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") || isWindowsAbsolute(path) }

    /// `needsWorkspaceBasenameLookup`: a bare file name with no folder.
    public static func needsBasenameLookup(_ relativePath: String) -> Bool {
        let t = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return t != "." && t != ".." && !t.isEmpty && !t.contains("/") && !t.contains("\\")
    }

    /// `pickWorkspaceBasenameMatch`: the exact basename first, else the one case-folded match.
    static func basenameMatch(_ name: String, _ entries: [Entry]) -> String? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let files = entries.filter(\.isFile)
        if let exact = files.first(where: { basename(Substring($0.path)) == target }) { return exact.path }
        let folded = files.filter { basename(Substring($0.path)).lowercased() == target.lowercased() }
        return folded.count == 1 ? folded[0].path : nil
    }

    /// `stripRepeatedWorkspacePrefix`: `demo/src/a.ts` cited inside `/repo/demo` is `src/a.ts`.
    static func strippingRepeatedPrefix(_ relativePath: String, cwd: String) -> String? {
        guard !isAbsolute(relativePath) else { return nil }
        let path = relativePath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        let root = cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let fold: (Substring) -> String = isWindowsAbsolute(cwd) ? { $0.lowercased() } : { String($0) }
        var count = min(root.count, path.count - 1)
        while count > 0 {
            if zip(root.suffix(count), path.prefix(count)).allSatisfy({ fold($0) == fold($1) }) {
                let rest = path.dropFirst(count).joined(separator: "/")
                return rest.isEmpty ? nil : rest
            }
            count -= 1
        }
        return nil
    }

    /// `workspaceLinkLookupQuery`: the search that may find the link's file, or nil when it names its file exactly.
    public static func query(_ relativePath: String, cwd: String) -> String? {
        let t = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAbsolute(t) || t.range(of: #"^(?:\.{1,2}|~)[\\/]"#, options: .regularExpression) != nil || t.hasSuffix("/") || t.hasSuffix("\\") {
            return nil
        }
        if needsBasenameLookup(t) { return t }
        return strippingRepeatedPrefix(t, cwd: cwd) ?? t
    }

    /// `pickWorkspaceLinkMatch`: the one file the link names, by basename, past a repeated prefix, or as a suffix.
    public static func match(_ relativePath: String, cwd: String, entries: [Entry]) -> String? {
        let t = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if needsBasenameLookup(t) { return basenameMatch(t, entries) }
        let hits = qualifiedMatches(t, cwd: cwd, entries: entries)
        return hits.count == 1 ? hits[0] : nil
    }

    /// `workspaceQualifiedPathMatches` (workspaceBasenameLookup.ts:90-119): the file past a repeated prefix, else
    /// every file the path ends.
    static func qualifiedMatches(_ t: String, cwd: String, entries: [Entry]) -> [String] {
        let files = entries.filter(\.isFile)
        func slashed(_ p: String) -> String { p.replacingOccurrences(of: "\\", with: "/") }
        if let stripped = strippingRepeatedPrefix(t, cwd: cwd) {
            let key: (String) -> String = isWindowsAbsolute(cwd) ? { slashed($0).lowercased() } : slashed
            if let hit = files.first(where: { key($0.path) == key(stripped) }) { return [hit.path] }
        }
        let suffix = slashed(t)
        return files.filter { slashed($0.path) == suffix || slashed($0.path).hasSuffix("/" + suffix) }.map(\.path)
    }

    /// `pickProjectLinkMatch` (5258 workspaceBasenameLookup.ts:126-166): the absolute path of the one file the link
    /// names across project roots, the thread's own included. A root whose basename search is ambiguous still counts,
    /// so another project's lone match never wins over it (#40986).
    public static func projectMatch(_ relativePath: String, searches: [(root: String, entries: [Entry])]) -> String? {
        let target = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = needsBasenameLookup(target)
        let folded = target.lowercased()
        func isFoldedMatch(_ entry: Entry) -> Bool { entry.isFile && basename(Substring(entry.path)).lowercased() == folded }
        var matches: [String] = []
        func add(_ path: String) {
            // Windows paths that differ only by case stay distinct: a directory can be case-sensitive.
            let key = isWindowsAbsolute(path) ? path.replacingOccurrences(of: "/", with: "\\") : path
            if !matches.contains(where: { (isWindowsAbsolute($0) ? $0.replacingOccurrences(of: "/", with: "\\") : $0) == key }) { matches.append(path) }
        }
        var rootHits = 0
        for search in searches {
            if bare {
                guard search.entries.contains(where: isFoldedMatch) else { continue }
                rootHits += 1
                if let hit = basenameMatch(target, search.entries) { add(join(search.root, hit)) }
            } else {
                qualifiedMatches(target, cwd: search.root, entries: search.entries).forEach { add(join(search.root, $0)) }
            }
        }
        if bare, rootHits > 1 {
            // A root's pick, or a root left ambiguous by case, can hide another file elsewhere.
            for search in searches { for entry in search.entries where isFoldedMatch(entry) { add(join(search.root, entry.path)) } }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// `resolveWorkspaceFilePath` for a relative match.
    public static func join(_ root: String, _ relative: String) -> String {
        let windows = isWindowsAbsolute(root)
        var r = root
        while r.hasSuffix("/") || r.hasSuffix("\\") { r.removeLast() }
        var rel = relative.replacingOccurrences(of: windows ? "/" : "\\", with: windows ? "\\" : "/")
        while rel.hasPrefix("/") || rel.hasPrefix("\\") { rel.removeFirst() }
        return r + (windows ? "\\" : "/") + rel
    }
}
