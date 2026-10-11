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

    /// `filterFilesystemBrowseEntries`: prefix matches, case-insensitive; dot folders only when the
    /// query starts with a dot; the exact name match, if any.
    public static func filter(_ entries: [Entry], query: String) -> (visible: [Entry], exact: Entry?) {
        let lower = query.lowercased()
        let showHidden = query.hasPrefix(".")
        let visible = entries.filter { $0.name.lowercased().hasPrefix(lower) && (showHidden || !$0.name.hasPrefix(".")) }
        return (visible, query.isEmpty ? nil : visible.first { $0.name == query })
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
