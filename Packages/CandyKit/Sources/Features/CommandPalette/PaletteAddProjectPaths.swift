import Foundation

/// The add-project flow's path rules (client-runtime state/projects.ts, state/filesystem.ts,
/// operations/projects.ts and shared/path.ts) for the POSIX paths a macOS or Linux server has.
/// Windows drive and UNC paths only ever get refused (`isUnsupportedWindowsProjectPath`).
public enum PaletteAddProjectPaths {
    // MARK: Path shape

    /// `isFilesystemBrowseQuery` on a POSIX server: the query is a path to browse.
    public static func isBrowseQuery(_ value: String) -> Bool {
        value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix(".\\") || value.hasPrefix("..\\")
            || value.hasPrefix("/") || value.hasPrefix("~/")
    }

    /// `isWindowsAbsolutePath`: `C:\`, `C:/` or `\\server\share`.
    public static func isWindowsAbsolute(_ value: String) -> Bool {
        let c = Array(value)
        if c.count >= 3, c[0].isLetter, c[0].isASCII, c[1] == ":", c[2] == "\\" || c[2] == "/" { return true }
        return value.hasPrefix("\\\\")
    }

    /// `isExplicitRelativePath`.
    public static func isExplicitRelative(_ value: String) -> Bool {
        value == "." || value == ".." || value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix(".\\") || value.hasPrefix("..\\")
    }

    /// `hasTrailingPathSeparator`: an absolute POSIX path ends in `/`; anything else in `/` or `\`.
    public static func hasTrailingSeparator(_ value: String) -> Bool {
        value.hasPrefix("/") ? value.hasSuffix("/") : value.hasSuffix("/") || value.hasSuffix("\\")
    }

    private static func lastSeparatorIndex(_ value: String) -> String.Index? {
        value.hasPrefix("/") ? value.lastIndex(of: "/") : value.lastIndex { $0 == "/" || $0 == "\\" }
    }

    /// `getBrowseDirectoryPath`: the query up to and including its last separator.
    public static func directoryPath(_ query: String) -> String {
        if hasTrailingSeparator(query) { return query }
        guard let i = lastSeparatorIndex(query) else { return query }
        return String(query[...i])
    }

    /// `getBrowseLeafPathSegment`: what follows the last separator.
    public static func leafSegment(_ query: String) -> String {
        guard let i = lastSeparatorIndex(query) else { return query }
        return String(query[query.index(after: i)...])
    }

    /// `normalizeProjectPathForDispatch`: trimmed, without trailing separators except a lone root.
    public static func normalizeForDispatch(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "/", trimmed != "\\" else { return trimmed }
        var out = Substring(trimmed)
        while let last = out.last, last == "/" || last == "\\", out.count > 1 { out = out.dropLast() }
        return String(out)
    }

    /// `getBrowseParentPath`: the parent directory with a trailing separator, nil at a root.
    public static func parentPath(_ path: String) -> String? {
        let trimmed = normalizeForDispatch(path)
        if trimmed.hasPrefix("/") {
            let segments = trimmed.dropFirst().split(separator: "/", omittingEmptySubsequences: true)
            if segments.isEmpty { return nil }
            if segments.count == 1 { return "/" }
            return "/" + segments.dropLast().joined(separator: "/") + "/"
        }
        guard let i = lastSeparatorIndex(trimmed) else { return nil }
        return String(trimmed[...i])
    }

    /// `canNavigateUp`.
    public static func canNavigateUp(_ path: String) -> Bool {
        hasTrailingSeparator(path) && parentPath(path) != nil
    }

    /// `ensureBrowseDirectoryPath`.
    public static func ensureDirectoryPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || hasTrailingSeparator(trimmed) { return trimmed }
        return trimmed + (trimmed.contains("\\") && !trimmed.hasPrefix("/") ? "\\" : "/")
    }

    /// `appendBrowsePathSegment`.
    public static func appendSegment(_ path: String, _ segment: String) -> String {
        let separator = !path.hasPrefix("/") && path.contains("\\") ? "\\" : "/"
        return directoryPath(path) + segment + separator
    }

    /// `resolveProjectPathForDispatch`: a `./` or `../` path resolves against `cwd`; anything else is
    /// only normalized (the server expands `~`).
    public static func resolveForDispatch(_ value: String, cwd: String?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isExplicitRelative(trimmed), let cwd, cwd.hasPrefix("/") else { return normalizeForDispatch(trimmed) }
        var segments = normalizeForDispatch(cwd).split(separator: "/").map(String.init)
        for part in trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            if part.isEmpty || part == "." { continue }
            if part == ".." { _ = segments.popLast(); continue }
            segments.append(String(part))
        }
        return normalizeForDispatch("/" + segments.joined(separator: "/"))
    }

    /// `inferProjectTitleFromPath`: the last path segment.
    public static func inferTitle(_ path: String) -> String {
        let normalized = normalizeForDispatch(path)
        return normalized.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? normalized
    }

    // MARK: Browse entries

    public struct Entry: Equatable, Sendable {
        public var name: String
        public var fullPath: String
        public init(name: String, fullPath: String) { self.name = name; self.fullPath = fullPath }
    }

    /// `filterFilesystemBrowseEntries` (4928 client-runtime state/filesystem.ts:86-143, #26376): exact,
    /// prefix, word boundary, substring, then fuzzy subsequence matches, best first; dot folders only when
    /// the query starts with a dot; the exact name match, if any. Swift compares names canonically, so
    /// Finder's decomposed names match composed typing without T3's NFC pass.
    public static func filter(_ entries: [Entry], query: String) -> (visible: [Entry], exact: Entry?) {
        let lower = query.lowercased()
        let showHidden = query.hasPrefix(".")
        let candidates = entries.filter { showHidden || !$0.name.hasPrefix(".") }
        let visible = lower.isEmpty ? candidates : candidates.enumerated()
            .compactMap { i, e in score(e.name.lowercased(), lower).map { (i, e, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 < $1.2 : $0.0 < $1.0 }
            .map(\.1)
        return (visible, query.isEmpty ? nil : visible.first { $0.name == query })
    }

    /// `scoreQueryMatch` (packages/shared/src/searchRanking.ts:88-140) with the browse tiers: exact 0,
    /// prefix 1000, boundary 2000 (markers space, -, _ and .), includes 3000, fuzzy 4000.
    static func score(_ valueString: String, _ queryString: String) -> Int? {
        let value = Array(valueString), query = Array(queryString)
        guard !value.isEmpty, !query.isEmpty else { return nil }
        let penalty = min(64, max(0, value.count - query.count))
        if value == query { return 0 }
        if value.starts(with: query) { return 1000 + penalty }
        func index(of needle: [Character]) -> Int? {
            guard needle.count <= value.count else { return nil }
            for i in 0...(value.count - needle.count) where Array(value[i..<(i + needle.count)]) == needle { return i }
            return nil
        }
        let boundary = [" ", "-", "_", "."].compactMap { m in index(of: Array(m) + query).map { $0 + 1 } }.min()
        if let boundary { return 2000 + boundary * 2 + penalty }
        if let i = index(of: query) { return 3000 + i * 2 + penalty }
        // `scoreSubsequenceMatch`.
        var qi = 0, first = -1, previous = -1, gaps = 0
        for (vi, c) in value.enumerated() where c == query[qi] {
            if first == -1 { first = vi }
            if previous != -1 { gaps += vi - previous - 1 }
            previous = vi
            qi += 1
            if qi == query.count { return 4000 + first * 2 + gaps * 3 + (vi - first + 1 - query.count) + min(64, value.count - query.count) }
        }
        return nil
    }

    /// `getFilesystemBrowseTabCompletion` (state/filesystem.ts:145-171, #28243): a single match enters the
    /// folder; several extend the query to their common prefix when it adds something and all start with it.
    public static func tabCompletion(_ visible: [Entry], filterQuery: String) -> (name: String, isComplete: Bool)? {
        guard let first = visible.first else { return nil }
        if visible.count == 1 { return (first.name, true) }
        var prefix = Array(first.name)
        for e in visible.dropFirst() {
            let c = Array(e.name)
            var n = 0
            while n < prefix.count, n < c.count, String(prefix[n]).lowercased() == String(c[n]).lowercased() { n += 1 }
            prefix = Array(prefix[0..<n])
        }
        let name = String(prefix), lowerName = name.lowercased()
        return lowerName.count > filterQuery.lowercased().count && visible.allSatisfy { $0.name.lowercased().hasPrefix(lowerName) } ? (name, false) : nil
    }

    /// `filterPinnedBrowseEntries`: the clone destination keeps the repository folder pinned at the
    /// end of the path, so a leaf equal to it filters nothing.
    public static func filterPinned(_ entries: [Entry], query: String, pinned: String) -> (visible: [Entry], exact: Entry?) {
        let visibleQuery = query == pinned ? "" : query
        return (filter(entries, query: visibleQuery).visible, query.isEmpty ? nil : entries.first { $0.name == query })
    }

    // MARK: New project and clone

    /// `newProjectFolderName`: "Pinball Stats" becomes "pinball-stats".
    public static func newProjectFolderName(_ name: String) -> String {
        let folded = name.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) }
        var slug = ""
        var dash = false
        for scalar in String(String.UnicodeScalarView(folded)).lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar); dash = false
            } else if !dash {
                slug.append("-"); dash = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        slug = String(slug.prefix(64))
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { return "project" }
        let reserved = ["con", "prn", "aux", "nul"] + (1...9).flatMap { ["com\($0)", "lpt\($0)"] }
        return reserved.contains(slug) ? "\(slug)-project" : slug
    }

    /// `getCloneDestinationPath`: `<directory>/<name>`, or the directory when there is no name.
    public static func cloneDestinationPath(_ directory: String, _ name: String?) -> String {
        let n = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? directory : ensureDirectoryPath(directory) + n
    }

    /// `getNewProjectPathPreview`.
    public static func newProjectPathPreview(root: String, name: String) -> String {
        cloneDestinationPath(root, newProjectFolderName(name))
    }

    /// `getCloneDirectoryName`: the repository's last path segment without `.git`; empty when a URL
    /// stops at its host or port.
    public static func cloneDirectoryName(_ value: String?) -> String {
        let raw = value ?? ""
        let withoutQuery = String(raw[..<(raw.firstIndex { $0 == "?" || $0 == "#" } ?? raw.endIndex)]).trimmingCharacters(in: .whitespaces)
        let scheme = withoutQuery.range(of: "://")
        // `/^[^/\\:]+@[^/\\:]+:/`: an scp-style remote such as `git@host:owner/repo.git`.
        let scp = withoutQuery.range(of: #"^[^/\\:]+@[^/\\:]+:"#, options: .regularExpression) != nil
        let hasHost = scheme != nil || scp
        let pathPart = scheme.map { String(withoutQuery[$0.upperBound...]) } ?? withoutQuery
        let segments = pathPart.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" })
            .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if hasHost, segments.count < 2 { return "" }
        let last = segments.last?.trimmingCharacters(in: .whitespaces) ?? ""
        if hasHost, segments.count == 2, !last.isEmpty, last.allSatisfy(\.isASCII), last.allSatisfy(\.isNumber) { return "" }
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    /// `normalizePastedCloneUrl`: the `owner/repo` shorthand becomes a public GitHub HTTPS URL; anything
    /// else stays as typed.
    public static func normalizePastedCloneUrl(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let shorthand = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]+(?:\.git)?$"#
        guard trimmed.range(of: shorthand, options: .regularExpression) != nil else { return trimmed }
        return "https://github.com/" + (trimmed.hasSuffix(".git") ? trimmed : trimmed + ".git")
    }

    /// `getCloneDestinationBrowsePath`: picking a folder keeps the repository folder at the end, unless
    /// the picked folder is that folder.
    public static func cloneDestinationBrowsePath(directory: String, selected: String, cloneName: String) -> String {
        let selectedPath = appendSegment(directory, selected)
        return selected == cloneName ? selectedPath : cloneDestinationPath(selectedPath, cloneName)
    }
}
